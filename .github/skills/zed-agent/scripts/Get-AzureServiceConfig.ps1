<#
.SYNOPSIS
    Loads the authoritative AzureServiceConfig.json (region/cloud/DR directory)
    from Mgmt-RecoverySvcs-DeploymentExtn with a live -> cache -> snapshot
    precedence.

.DESCRIPTION
    Source-of-truth file:
      https://msazure.visualstudio.com/One/_git/Mgmt-RecoverySvcs-DeploymentExtn
        path: src/DeploymentInfra/EV2DeploymentEngine/SchemaInput/AzureServiceConfig.json

    Resolution order (default — live-first):
      1. Live  : ADO REST Items API (requires `az login`). Written to cache.
      2. Cache : .zed-agent/cache/AzureServiceConfig.json   (any age — only
                 used if the live fetch fails).
      3. Snap  : .github/skills/zed-agent/fixtures/AzureServiceConfig.snapshot.json
                 (committed offline fallback; last resort, surfaces a warning).

    -PreferCache  reverses (1)/(2): use cache if fresh (<= MaxAgeHours), else live.
                  Useful for tight loops where staleness of <=24h is acceptable.
    -NoCache      forces a live fetch and refuses every fallback.
    -OfflineOnly  skips the network entirely (cache -> snapshot).

.OUTPUTS
    PSCustomObject:
      data    = <parsed JSON object: $schema, Version, DefaultMacros, Clouds[]>
      source  = 'live' | 'cache' | 'snapshot'
      path    = <on-disk path actually used>
      fetchedAt = ISO-8601 UTC
      ageHours  = double (cache only; $null otherwise)
#>
[CmdletBinding()]
param(
    [string]$CachePath,
    [string]$SnapshotPath,
    [int]   $MaxAgeHours = 24,
    [switch]$NoCache,
    [switch]$OfflineOnly,
    [switch]$PreferCache
)

$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\')).Path
if (-not $CachePath)    { $CachePath    = Join-Path $repoRoot '.zed-agent\cache\AzureServiceConfig.json' }
if (-not $SnapshotPath) { $SnapshotPath = Join-Path $repoRoot '.github\skills\zed-agent\fixtures\AzureServiceConfig.snapshot.json' }
$cacheDir  = Split-Path $CachePath -Parent
$metaPath  = [System.IO.Path]::ChangeExtension($CachePath, '.meta.json')

# ── ADO endpoint constants ─────────────────────────────────────────────
$adoOrg       = 'msazure.visualstudio.com'
$adoProject   = 'One'
$adoRepo      = 'Mgmt-RecoverySvcs-DeploymentExtn'
$adoItemPath  = '/src/DeploymentInfra/EV2DeploymentEngine/SchemaInput/AzureServiceConfig.json'
$adoResource  = '499b84ac-1321-427f-aa17-267ca6975798'  # ADO

function Read-LocalAsc {
    param([string]$Path, [string]$Source)
    if (-not (Test-Path $Path)) { return $null }
    $raw  = Get-Content $Path -Raw -ErrorAction Stop
    $obj  = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $obj.Clouds) { throw "ASC at $Path missing required 'Clouds' array." }
    $age  = $null
    if ($Source -eq 'cache') {
        $age = ((Get-Date).ToUniversalTime() - (Get-Item $Path).LastWriteTimeUtc).TotalHours
    }
    [PSCustomObject]@{
        data      = $obj
        source    = $Source
        path      = $Path
        fetchedAt = (Get-Item $Path).LastWriteTimeUtc.ToString('o')
        ageHours  = $age
    }
}

function Try-FetchLiveAsc {
    try {
        $token = az account get-access-token --resource $adoResource --query accessToken -o tsv 2>$null
        if (-not $token) { return $null }
        $uri = "https://$adoOrg/$adoProject/_apis/git/repositories/$adoRepo/items?path=$adoItemPath&api-version=7.1"
        $resp = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -ne 200) { return $null }
        $body = $resp.Content
        if ($body -is [byte[]]) {
            # ADO Items API returns application/octet-stream; decode UTF-8 (strip BOM if present).
            if ($body.Length -ge 3 -and $body[0] -eq 0xEF -and $body[1] -eq 0xBB -and $body[2] -eq 0xBF) {
                $body = [System.Text.Encoding]::UTF8.GetString($body, 3, $body.Length - 3)
            } else {
                $body = [System.Text.Encoding]::UTF8.GetString($body)
            }
        }
        $obj  = $body | ConvertFrom-Json -ErrorAction Stop
        if (-not $obj.Clouds) { return $null }

        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
        Set-Content -Path $CachePath -Value $body -Encoding utf8 -NoNewline
        $sha = (Get-FileHash -Path $CachePath -Algorithm SHA256).Hash
        $meta = [PSCustomObject]@{
            fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
            sha256    = $sha
            sourceUri = $uri
            cloudCount = @($obj.Clouds).Count
        }
        Set-Content -Path $metaPath -Value ($meta | ConvertTo-Json) -Encoding utf8
        return [PSCustomObject]@{
            data      = $obj
            source    = 'live'
            path      = $CachePath
            fetchedAt = $meta.fetchedAt
            ageHours  = 0.0
        }
    } catch {
        Write-Verbose "Live ASC fetch failed: $($_.Exception.Message)"
        return $null
    }
}

# ── Resolution ─────────────────────────────────────────────────────────
if ($NoCache -and $OfflineOnly) { throw "-NoCache and -OfflineOnly are mutually exclusive." }
if ($NoCache -and $PreferCache) { throw "-NoCache and -PreferCache are mutually exclusive." }

if ($NoCache) {
    $live = Try-FetchLiveAsc
    if ($live) { return $live }
    throw "Live ASC fetch failed and -NoCache forbids fallback. Run 'az login' or drop -NoCache."
}

if ($OfflineOnly) {
    $cached = Read-LocalAsc -Path $CachePath -Source 'cache'
    if ($cached) { return $cached }
    $snap = Read-LocalAsc -Path $SnapshotPath -Source 'snapshot'
    if ($snap) { Write-Warning "Using committed ASC snapshot at $SnapshotPath (offline mode)."; return $snap }
    throw "No cache and no snapshot available at $CachePath / $SnapshotPath."
}

if ($PreferCache) {
    # Opt-in cache-first path for hot loops where <=24h staleness is acceptable.
    $cached = Read-LocalAsc -Path $CachePath -Source 'cache'
    if ($cached -and $cached.ageHours -le $MaxAgeHours) { return $cached }
}

# DEFAULT PATH: live first. Cache and snapshot exist only to keep the agent
# working when ADO/auth is unreachable.
$live = Try-FetchLiveAsc
if ($live) { return $live }

$cached = Read-LocalAsc -Path $CachePath -Source 'cache'
if ($cached) {
    Write-Warning "Live ASC fetch failed; using local cache (age=$([math]::Round($cached.ageHours,1))h). Run 'az login' to refresh."
    return $cached
}

$snap = Read-LocalAsc -Path $SnapshotPath -Source 'snapshot'
if (-not $snap) { throw "Live ASC fetch failed and no cache or snapshot is available at $CachePath / $SnapshotPath. Run 'az login' or restore the snapshot." }
Write-Warning "Live ASC fetch failed AND no local cache present; falling back to committed snapshot at $SnapshotPath (may be stale). Run 'az login' to refresh."
return $snap
