<#
.SYNOPSIS
    Parses a Service Datacenter Settings (SDS) JSON file and emits a
    normalized stamp inventory grouped by cloud.

.DESCRIPTION
    Tier 2 of the YAML+SDS inventory mechanism (Phase 11.3b).

    Reads an SDS JSON (Phobos 2022 schema or a service-specific variant),
    walks CloudSettings[] → StampSettings[] via dotted-path field mappings,
    and returns a flat list of normalized stamps plus a per-cloud grouping.

    Field mappings are resolved in this order:
      1. -FieldMapping hashtable passed in.
      2. service-config.json → sdsFieldMapping (committed per-service learning).
      3. Phobos 2022 defaults (the shape observed in Mgmt-RecoverySvcs-DataMover
         and Mgmt-RecoverySvcs-BackupDataPlane).

    Sovereign clouds (Fairfax, Mooncake, USNat, USSec) MUST come from SDS —
    AME-tenant Kusto is not reachable by this agent. Public-cloud results
    are reconciled against Kusto in Get-StampInventory.ps1.

.PARAMETER SdsPath
    Absolute path to the SDS JSON file. Required.

.PARAMETER Cloud
    Optional CloudName filter (matches SDS CloudSettings[].CloudName exactly,
    case-insensitive). If omitted, all clouds are returned.

.PARAMETER FieldMapping
    Optional hashtable overriding sdsFieldMapping from service-config.json.

.PARAMETER ServiceConfigPath
    Path to service-config.json. Defaults to .github/skills/zed-agent/service-config.json.

.PARAMETER Detect
    Skip inventory extraction; instead, return the resolved field mapping
    plus a sample value from the first stamp of the first cloud at each
    mapped path. Used by setup-service group 11.3b to confirm the mapping
    with the owner before persisting it.

.OUTPUTS
    PSCustomObject:
      service     = <Metadata.ServiceShortName>
      schemaUri   = <$schema>
      source      = <SdsPath>
      fetchedAt   = ISO-8601 UTC
      hash        = sha256 of normalized stamps array (sorted for stability)
      mapping     = effective field mapping used
      byCloud     = @{ <CloudName> = @(<stamp>...) }
      stamps      = flat @(<stamp>) — each:
                      cloud, stampId, stampName, clusterName,
                      dcShortName, region, deploymentName, dsmsRegion
      errors      = @(<dotted-path that failed to resolve>)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SdsPath,
    [string]$Cloud,
    [hashtable]$FieldMapping,
    [string]$ServiceConfigPath,
    [switch]$Detect
)

$ErrorActionPreference = 'Stop'

# ── Resolve paths ──────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $SdsPath)) {
    throw "SDS file not found: $SdsPath"
}
if (-not $ServiceConfigPath) {
    $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json'
}

# ── Defaults (Phobos 2022 shape) ───────────────────────────────────────
$defaultMapping = @{
    cloudArrayPath     = 'CloudSettings'
    cloudNameField     = 'CloudName'
    stampsArrayField   = 'StampSettings'
    stampIdField       = 'StampId'
    stampNamePath      = 'Macros.__StampName__'
    clusterNamePath    = 'Macros.__ClusterName__'
    dcShortNamePath    = 'Macros.__DatacenterShortName__'
    regionPath         = 'Macros.__ClusterLocation__'
    deploymentNamePath = 'Macros.__DeploymentName__'
    dsmsRegionPath     = 'Macros.__DsmsRegion__'
}

# ── Compose effective mapping ──────────────────────────────────────────
$effective = @{}
foreach ($k in $defaultMapping.Keys) { $effective[$k] = $defaultMapping[$k] }

if (Test-Path -LiteralPath $ServiceConfigPath) {
    try {
        $svcCfg = Get-Content -LiteralPath $ServiceConfigPath -Raw | ConvertFrom-Json
        if ($svcCfg.PSObject.Properties.Name -contains 'sdsFieldMapping' -and $svcCfg.sdsFieldMapping) {
            foreach ($p in $svcCfg.sdsFieldMapping.PSObject.Properties) {
                if ($p.Value) { $effective[$p.Name] = [string]$p.Value }
            }
        }
    } catch {
        Write-Verbose "Could not read sdsFieldMapping from service-config.json: $_"
    }
}

if ($FieldMapping) {
    foreach ($k in $FieldMapping.Keys) {
        if ($FieldMapping[$k]) { $effective[$k] = [string]$FieldMapping[$k] }
    }
}

# ── Dotted-path resolver ───────────────────────────────────────────────
function Resolve-Path-Value {
    param([object]$Root, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $current = $Root
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$part]
        if (-not $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

# ── Parse SDS ──────────────────────────────────────────────────────────
try {
    $sds = Get-Content -LiteralPath $SdsPath -Raw | ConvertFrom-Json
} catch {
    throw "Failed to parse SDS JSON at ${SdsPath}: $_"
}

$schemaUri = $null
if ($sds.PSObject.Properties.Name -contains '$schema') { $schemaUri = $sds.'$schema' }
$serviceShortName = $null
if ($sds.PSObject.Properties.Name -contains 'Metadata' -and $sds.Metadata) {
    if ($sds.Metadata.PSObject.Properties.Name -contains 'ServiceShortName') {
        $serviceShortName = $sds.Metadata.ServiceShortName
    }
}

$clouds = Resolve-Path-Value -Root $sds -Path $effective.cloudArrayPath
if ($null -eq $clouds) {
    throw "SDS cloud array path '$($effective.cloudArrayPath)' did not resolve in $SdsPath."
}

# ── Detect mode: return mapping + sample values, skip extraction ───────
if ($Detect) {
    $firstCloud = @($clouds)[0]
    $firstStamp = $null
    if ($firstCloud) {
        $stamps0 = Resolve-Path-Value -Root $firstCloud -Path $effective.stampsArrayField
        if ($stamps0) { $firstStamp = @($stamps0)[0] }
    }
    $samples = [ordered]@{}
    foreach ($k in $effective.Keys) {
        $path = $effective[$k]
        $sample = $null
        switch ($k) {
            'cloudArrayPath'   { $sample = "<array len $((@($clouds)).Count)>" }
            'cloudNameField'   { if ($firstCloud) { $sample = Resolve-Path-Value -Root $firstCloud -Path $path } }
            'stampsArrayField' { if ($firstCloud) { $arr = Resolve-Path-Value -Root $firstCloud -Path $path; if ($arr) { $sample = "<array len $((@($arr)).Count)>" } } }
            default            { if ($firstStamp) { $sample = Resolve-Path-Value -Root $firstStamp -Path $path } }
        }
        $samples[$k] = [pscustomobject]@{ path = $path; sample = $sample }
    }
    return [pscustomobject]@{
        service   = $serviceShortName
        schemaUri = $schemaUri
        source    = $SdsPath
        mapping   = $effective
        samples   = $samples
    }
}

# ── Extract stamps ─────────────────────────────────────────────────────
$errors = New-Object System.Collections.Generic.List[string]
$flat   = New-Object System.Collections.Generic.List[object]
$byCloud = [ordered]@{}

foreach ($cloudObj in @($clouds)) {
    $cloudName = Resolve-Path-Value -Root $cloudObj -Path $effective.cloudNameField
    if (-not $cloudName) {
        $errors.Add("CloudName missing at path '$($effective.cloudNameField)'") | Out-Null
        continue
    }
    if ($Cloud -and ($Cloud -ine $cloudName)) { continue }

    $stampArr = Resolve-Path-Value -Root $cloudObj -Path $effective.stampsArrayField
    if ($null -eq $stampArr) {
        $errors.Add("Cloud '$cloudName' has no stamps array at '$($effective.stampsArrayField)'") | Out-Null
        continue
    }

    $cloudList = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($stampArr)) {
        $row = [pscustomobject]@{
            cloud          = [string]$cloudName
            stampId        = [string](Resolve-Path-Value -Root $s -Path $effective.stampIdField)
            stampName      = [string](Resolve-Path-Value -Root $s -Path $effective.stampNamePath)
            clusterName    = [string](Resolve-Path-Value -Root $s -Path $effective.clusterNamePath)
            dcShortName    = [string](Resolve-Path-Value -Root $s -Path $effective.dcShortNamePath)
            region         = [string](Resolve-Path-Value -Root $s -Path $effective.regionPath)
            deploymentName = [string](Resolve-Path-Value -Root $s -Path $effective.deploymentNamePath)
            dsmsRegion     = [string](Resolve-Path-Value -Root $s -Path $effective.dsmsRegionPath)
        }
        if (-not $row.stampId) {
            $errors.Add("Cloud '$cloudName' has a stamp with no '$($effective.stampIdField)'") | Out-Null
        }
        $flat.Add($row) | Out-Null
        $cloudList.Add($row) | Out-Null
    }
    $byCloud[[string]$cloudName] = $cloudList.ToArray()
}

# ── Stable hash for drift detection ────────────────────────────────────
$sorted = $flat | Sort-Object cloud, stampId
$canonical = $sorted | ForEach-Object {
    "$($_.cloud)|$($_.stampId)|$($_.stampName)|$($_.dcShortName)|$($_.region)|$($_.deploymentName)"
}
$joined = ($canonical -join "`n")
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
} finally {
    $sha.Dispose()
}

return [pscustomobject]@{
    service   = $serviceShortName
    schemaUri = $schemaUri
    source    = (Resolve-Path -LiteralPath $SdsPath).Path
    fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
    hash      = $hash
    mapping   = $effective
    byCloud   = $byCloud
    stamps    = $flat.ToArray()
    errors    = $errors.ToArray()
}
