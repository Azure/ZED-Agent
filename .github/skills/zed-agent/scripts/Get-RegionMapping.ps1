<#
.SYNOPSIS
    Fetches AzureServiceConfig.json from DeploymentExtn repo to extract region mappings.

.DESCRIPTION
    Reads the service's AzureServiceConfig.json region source (Phobos 2022 schema) from
    the ADO repository named in service-config.json (regions.ascRepo) via ADO Git Items
    API. This is the single source of truth for the service's deployment regions.

    Each region entry includes:
    - DataCenterName    : SafeFly display name (e.g., "East Asia") — use for targetedRegions
    - RegionShortName   : Azure short name (e.g., "eastasia") — matches CCOA exclusion format
    - StampPrefix       : Region abbreviation (e.g., "ea")
    - StampCount        : 1 per datacenter entry (ASC is per-DC, not per-stamp)
    - Ev2Geography      : Geography grouping (e.g., "Asia Pacific")
    - DatacenterType    : Deployment type array (e.g., ["ACTIVE", "HAS_PASSIVE"])

    Only ACTIVE datacenters are returned by default (PASSIVE entries are excluded to
    avoid duplicate regions).

    Source: the AzureServiceConfig.json named by service-config.json (regions.ascRepo / regions.ascPath).
    Branch: regions.ascBranch (default 'develop'; override via -AscBranch)
    Cached locally for 24 hours to avoid repeated API calls.

.PARAMETER CloudName
    Which cloud to extract regions for. Default: "Public".
    Valid values: Public, Fairfax, Mooncake, USNat, USSec, Canary, BVTD3, Bleu.

.PARAMETER AllClouds
    If set, returns regions from all deployment clouds (Public, Fairfax, Mooncake, USNat, USSec).

.PARAMETER ExcludeRegions
    Array of region short names (e.g., "eastus2", "westeurope") to exclude from the output.
    Used to subtract CCOA-excluded regions and return only targeted regions.

.PARAMETER AscRepo
    ADO repository name for AzureServiceConfig.json. Default: service-config.json -> regions.ascRepo.

.PARAMETER AscPath
    Path within the repo to AzureServiceConfig.json.
    Default: service-config.json -> regions.ascPath.

.PARAMETER AscBranch
    Branch to fetch from. Default: service-config.json -> regions.ascBranch (else 'develop').

.PARAMETER ServiceConfigPath
    Path to service-config.json (defaults to the co-located config one level up from scripts/).
    The region source (regions.ascRepo/ascPath/ascBranch/supplementaryRegions) is read from here.

.PARAMETER CachePath
    Local cache file path. Default: $env:TEMP\zed-asc-cache.json.
    Set to empty string to disable caching.

.PARAMETER CacheTtlHours
    Cache time-to-live in hours. Default: 24.

.PARAMETER ForceRefresh
    Bypass cache and fetch fresh from ADO API.

.PARAMETER IncludePlaceholders
    DEPRECATED — no-op, kept for backward compatibility. ASC does not have placeholders.

.PARAMETER RepoRoot
    DEPRECATED — no-op, kept for backward compatibility. ASC is fetched from ADO API.

.OUTPUTS
    Array of PSCustomObject with properties:
    DataCenterName, RegionShortName, StampPrefix, StampCount, Ev2Geography, DatacenterType

.EXAMPLE
    # Get all active Public regions
    .\Get-RegionMapping.ps1

.EXAMPLE
    # Get Public regions excluding CCOA-excluded ones (returns targeted regions for SafeFly)
    .\Get-RegionMapping.ps1 -ExcludeRegions @("eastus2", "westeurope", "centralus")

.EXAMPLE
    # Get Fairfax (sovereign) regions
    .\Get-RegionMapping.ps1 -CloudName Fairfax

.EXAMPLE
    # Get all deployment clouds
    .\Get-RegionMapping.ps1 -AllClouds

.EXAMPLE
    # Force fresh fetch bypassing cache
    .\Get-RegionMapping.ps1 -ForceRefresh
#>
[CmdletBinding()]
param(
    [ValidateSet("Public", "Fairfax", "Mooncake", "USNat", "USSec", "Canary", "BVTD3", "Bleu")]
    [string]$CloudName = "Public",

    [switch]$AllClouds,

    [string[]]$ExcludeRegions = @(),

    # Region source-of-truth — resolved from service-config.json (regions.*) when not passed explicitly.
    [string]$AscRepo = "",

    [string]$AscPath = "",

    [string]$AscBranch = "",

    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\service-config.json'),

    [string]$CachePath = (Join-Path $env:TEMP "zed-asc-cache.json"),

    [int]$CacheTtlHours = 24,

    [switch]$ForceRefresh,

    # DEPRECATED — kept for backward compatibility (no-op)
    [switch]$IncludePlaceholders,
    [string]$RepoRoot
)

# --- Resolve region source from service config (params override; never hard-code a service's region source) ---
$regionCfg = $null
try {
    $cfg = & (Join-Path $PSScriptRoot 'Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath
    $regionCfg = $cfg.regions
} catch {
    Write-Verbose "Could not load service config for region source ($ServiceConfigPath): $_"
}
if (-not $AscRepo   -and $regionCfg) { $AscRepo   = [string]$regionCfg.ascRepo }
if (-not $AscPath   -and $regionCfg) { $AscPath   = [string]$regionCfg.ascPath }
if (-not $AscBranch -and $regionCfg) { $AscBranch = [string]$regionCfg.ascBranch }
if (-not $AscBranch) { $AscBranch = "develop" }
if (-not $AscRepo -or -not $AscPath) {
    throw "Region source is not configured. Set regions.ascRepo and regions.ascPath in service-config.json (or pass -AscRepo/-AscPath). ZED must not assume a service's region source."
}

if ($IncludePlaceholders) {
    Write-Warning "-IncludePlaceholders is deprecated and has no effect. ASC does not have placeholder entries."
}
if ($RepoRoot) {
    Write-Warning "-RepoRoot is deprecated and has no effect. Region data is now fetched from $AscRepo via ADO API."
}

# --- Fetch or load cached AzureServiceConfig.json ---

$useCache = $false
if ($CachePath -and -not $ForceRefresh -and (Test-Path $CachePath)) {
    $cacheAge = (Get-Date) - (Get-Item $CachePath).LastWriteTime
    if ($cacheAge.TotalHours -lt $CacheTtlHours) {
        $useCache = $true
        Write-Verbose "Using cached ASC (age: $([math]::Round($cacheAge.TotalHours, 1))h, TTL: ${CacheTtlHours}h): $CachePath"
    }
}

if ($useCache) {
    $asc = Get-Content $CachePath -Raw | ConvertFrom-Json
} else {
    Write-Verbose "Fetching AzureServiceConfig.json from $AscRepo (branch: $AscBranch)"
    try {
        $adoToken = (az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" --query accessToken -o tsv 2>$null)
        if (-not $adoToken) {
            throw "Failed to acquire ADO access token via 'az account get-access-token'."
        }

        $encodedPath = [System.Uri]::EscapeDataString($AscPath)
        $apiUrl = "https://dev.azure.com/msazure/One/_apis/git/repositories/$AscRepo/items" +
                  "?path=$encodedPath" +
                  "&versionDescriptor.version=$AscBranch" +
                  "&versionDescriptor.versionType=branch" +
                  "&api-version=7.1"

        $asc = Invoke-RestMethod -Uri $apiUrl -Headers @{ Authorization = "Bearer $adoToken" } -ErrorAction Stop

        # Validate the response has expected structure
        if (-not $asc.Clouds) {
            throw "Fetched ASC does not contain 'Clouds' array — unexpected schema."
        }

        # Write to cache atomically (write temp, then move)
        if ($CachePath) {
            $tempFile = "$CachePath.tmp"
            $asc | ConvertTo-Json -Depth 20 | Set-Content $tempFile -Encoding utf8
            Move-Item $tempFile $CachePath -Force
            Write-Verbose "ASC cached to: $CachePath"
        }
    } catch {
        # If fetch fails but stale cache exists, use it with a warning
        if ($CachePath -and (Test-Path $CachePath)) {
            $staleAge = (Get-Date) - (Get-Item $CachePath).LastWriteTime
            Write-Warning "ADO fetch failed: $($_.Exception.Message). Using stale cache (age: $([math]::Round($staleAge.TotalHours, 1))h)."
            $asc = Get-Content $CachePath -Raw | ConvertFrom-Json
        } else {
            throw "Failed to fetch AzureServiceConfig.json from ADO and no cache available: $($_.Exception.Message)"
        }
    }
}

# --- Determine which clouds to query ---

if ($AllClouds) {
    $targetCloudNames = @("Public", "Fairfax", "Mooncake", "USNat", "USSec")
    $clouds = $asc.Clouds | Where-Object { $_.Name -in $targetCloudNames }
    Write-Verbose "AllClouds mode: querying $($targetCloudNames -join ', ')"
} else {
    $clouds = $asc.Clouds | Where-Object { $_.Name -eq $CloudName }
    if (-not $clouds) {
        $available = ($asc.Clouds | ForEach-Object { $_.Name }) -join ', '
        throw "Cloud '$CloudName' not found in ASC. Available: $available"
    }
}

# --- Parse flat DataCenters[] — ACTIVE only to avoid duplicates ---

$regions = @{}

foreach ($cloud in $clouds) {
    foreach ($dc in $cloud.DataCenters) {
        # Skip non-ACTIVE datacenters (PASSIVE entries duplicate the same region)
        $dcTypes = @($dc.DatacenterType)
        if ($dcTypes -notcontains "ACTIVE") { continue }

        $dcName = $dc.FriendlyName
        $regionShort = $dc.Ev2RegionName
        $prefix = $dc.ShortName

        # Skip entries missing required fields
        if ([string]::IsNullOrWhiteSpace($dcName) -or [string]::IsNullOrWhiteSpace($regionShort)) { continue }

        # Dedupe by Ev2RegionName within each cloud (first ACTIVE entry wins)
        $regionKey = "$($cloud.Name)|$regionShort"
        if ($regions.ContainsKey($regionKey)) { continue }

        $regions[$regionKey] = @{
            DataCenterName  = $dcName
            RegionShortName = $regionShort
            StampPrefix     = $prefix
            StampCount      = 1
            Ev2Geography    = $dc.Ev2Geography
            DatacenterType  = $dcTypes
        }
    }
}

# --- Supplementary SafeFly regions not yet in AzureServiceConfig.json ---
# SafeFly-only regions without physical deployment stamps, declared per-service in
# service-config.json -> regions.supplementaryRegions (each: { DataCenterName, RegionShortName }).
$supplementaryRegions = @()
if ($regionCfg -and $regionCfg.supplementaryRegions) {
    $supplementaryRegions = @($regionCfg.supplementaryRegions)
}

# Build a set of existing RegionShortNames for dedup
$existingShortNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($r in $regions.Values) { [void]$existingShortNames.Add($r.RegionShortName) }

foreach ($sup in $supplementaryRegions) {
    if (-not $existingShortNames.Contains($sup.RegionShortName)) {
        $regions["supplementary|$($sup.RegionShortName)"] = @{
            DataCenterName  = $sup.DataCenterName
            RegionShortName = $sup.RegionShortName
            StampPrefix     = "supplementary"
            StampCount      = 0
            Ev2Geography    = "Supplementary"
            DatacenterType  = @()
        }
        Write-Verbose "Supplementary region added (not in ASC): $($sup.DataCenterName)"
    }
}

# --- Apply exclusions (match on RegionShortName, case-insensitive) ---
$excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($r in $ExcludeRegions) { [void]$excludeSet.Add($r) }

# Normalize DataCenterName mismatches between ASC and SafeFly API
# 6 fixups still needed (ASC uses Gov/DoD naming without spaces)
$nameFixups = @{
    "Qatar central"  = "Qatar Central"
    "USDoD Central"  = "US DoD Central"
    "USDoD East"     = "US DoD East"
    "USGov Arizona"  = "US Gov Arizona"
    "USGov Texas"    = "US Gov Texas"
    "USGov Virginia" = "US Gov Virginia"
}

$result = $regions.Values |
    Where-Object { -not $excludeSet.Contains($_.RegionShortName) } |
    Sort-Object { $_.DataCenterName } |
    ForEach-Object {
        if ($nameFixups.ContainsKey($_.DataCenterName)) {
            $_.DataCenterName = $nameFixups[$_.DataCenterName]
        }
        [PSCustomObject]$_
    }

$ascCount = ($result | Where-Object { $_.StampPrefix -ne "supplementary" } | Measure-Object).Count
$supCount = ($result | Where-Object { $_.StampPrefix -eq "supplementary" } | Measure-Object).Count
Write-Verbose "Source: $AscRepo ($AscBranch) | Clouds: $(($clouds | ForEach-Object { $_.Name }) -join ', ') | ASC regions: $ascCount | Supplementary: $supCount | Excluded: $($ExcludeRegions.Count) | Total returned: $(($result | Measure-Object).Count)"

return $result
