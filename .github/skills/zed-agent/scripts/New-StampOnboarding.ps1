<#
.SYNOPSIS
    L-13: Computes parameter deltas for onboarding new stamps or reclassifying
    existing stamps across all 4 production pipelines.

.DESCRIPTION
    Given a set of stamps with their prefix, region, pipeline type (SFRP/SFMC),
    and cloud, computes the exact parameter changes needed for each production
    pipeline. Applies the L-10 4-step reclassification rule:
      1. Add region to target pipeline's PubRegions
      2. Remove stamp from target pipeline's PublicExcludestamps
      3. Keep stamp in source pipeline's PublicExcludestamps
      4. Optionally drop the region from source pipeline's PubRegions (if no
         other stamps remain in that region)

    Emits a reviewable diff — never silently writes production config.

.PARAMETER NewStamps
    Array of stamp objects. Each must have: prefix, region, pipelineType ('SFRP' or 'SFMC'), cloud.
    Example: @(@{prefix='uac'; region='uaecentral'; pipelineType='SFRP'; cloud='Public'})

.PARAMETER ServiceConfigPath
    Path to service-config.json.

.PARAMETER PipelineCatalogPath
    Path to pipeline-catalog.json.

.OUTPUTS
    PSCustomObject with per-pipeline deltas (additions and removals to PubRegions
    and PublicExcludestamps), plus a human-readable diff summary.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][array]$NewStamps,
    [string]$ServiceConfigPath  = (Join-Path $PSScriptRoot '..\service-config.json'),
    [string]$PipelineCatalogPath = (Join-Path $PSScriptRoot '..\pipeline-catalog.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ServiceConfigPath))   { throw "service-config.json not found at $ServiceConfigPath" }
if (-not (Test-Path $PipelineCatalogPath)) { throw "pipeline-catalog.json not found at $PipelineCatalogPath" }

$catalog = Get-Content $PipelineCatalogPath -Raw | ConvertFrom-Json

# Validate input
foreach ($stamp in $NewStamps) {
    if (-not $stamp.prefix)       { throw "NEW_STAMP_MISSING_FIELD: every stamp must have 'prefix'. Got: $($stamp | ConvertTo-Json -Compress)" }
    if (-not $stamp.region)       { throw "NEW_STAMP_MISSING_FIELD: every stamp must have 'region'. Got: $($stamp | ConvertTo-Json -Compress)" }
    if (-not $stamp.pipelineType) { throw "NEW_STAMP_MISSING_FIELD: every stamp must have 'pipelineType' (SFRP or SFMC). Got: $($stamp | ConvertTo-Json -Compress)" }
    if ($stamp.pipelineType -notin @('SFRP','SFMC')) {
        throw "NEW_STAMP_INVALID_TYPE: pipelineType must be 'SFRP' or 'SFMC', got '$($stamp.pipelineType)' for prefix '$($stamp.prefix)'."
    }
    if (-not $stamp.cloud) { throw "NEW_STAMP_MISSING_FIELD: every stamp must have 'cloud'. Got: $($stamp | ConvertTo-Json -Compress)" }
}

# Identify production pipelines and their cluster type
$prodPipelines = @{}
if ($catalog.production) {
    foreach ($p in $catalog.production.PSObject.Properties) {
        $pEntry = $p.Value
        $ct = if ($pEntry.PSObject.Properties['clusterType']) { [string]$pEntry.clusterType } else { $null }
        $prodPipelines[$p.Name] = @{
            entry       = $pEntry
            clusterType = $ct
        }
    }
}

# Map pipeline type to clusterType convention
$typeToClusterType = @{ 'SFRP' = 'sfrp'; 'SFMC' = 'sfmc' }

# Build deltas per pipeline
$deltas = @{}
foreach ($pKey in $prodPipelines.Keys) {
    $deltas[$pKey] = @{
        addToRegions           = @()
        removeFromExcludeStamps = @()
        addToExcludeStamps     = @()
        reason                 = @()
    }
}

foreach ($stamp in $NewStamps) {
    $targetCt = $typeToClusterType[$stamp.pipelineType]

    foreach ($pKey in $prodPipelines.Keys) {
        $pInfo = $prodPipelines[$pKey]
        $pCt   = $pInfo.clusterType

        if ($pCt -eq $targetCt) {
            # This is the TARGET pipeline — stamp belongs here
            # Step 1: Add region to PubRegions
            $deltas[$pKey].addToRegions += $stamp.region
            # Step 2: Remove stamp from PublicExcludestamps (if it was there)
            $deltas[$pKey].removeFromExcludeStamps += $stamp.prefix
            $deltas[$pKey].reason += "Onboard '$($stamp.prefix)' (region=$($stamp.region), type=$($stamp.pipelineType)): add region, un-exclude stamp"
        }
        else {
            # This is a SOURCE/other pipeline — stamp does NOT belong here
            # Step 3: Keep/add stamp in PublicExcludestamps
            $deltas[$pKey].addToExcludeStamps += $stamp.prefix
            $deltas[$pKey].reason += "Exclude '$($stamp.prefix)' (type=$($stamp.pipelineType) != pipeline ct=$pCt)"
        }
    }
}

# Deduplicate
foreach ($pKey in $deltas.Keys) {
    $deltas[$pKey].addToRegions            = @($deltas[$pKey].addToRegions | Sort-Object -Unique)
    $deltas[$pKey].removeFromExcludeStamps = @($deltas[$pKey].removeFromExcludeStamps | Sort-Object -Unique)
    $deltas[$pKey].addToExcludeStamps      = @($deltas[$pKey].addToExcludeStamps | Sort-Object -Unique)
}

# Build human-readable diff
$diffLines = @("# Stamp Onboarding Deltas", "")
foreach ($pKey in ($deltas.Keys | Sort-Object)) {
    $d = $deltas[$pKey]
    $diffLines += "## Pipeline: $pKey"
    if ($d.addToRegions.Count -gt 0) {
        $diffLines += "  + PubRegions: $($d.addToRegions -join ', ')"
    }
    if ($d.removeFromExcludeStamps.Count -gt 0) {
        $diffLines += "  - PublicExcludestamps (remove): $($d.removeFromExcludeStamps -join ', ')"
    }
    if ($d.addToExcludeStamps.Count -gt 0) {
        $diffLines += "  + PublicExcludestamps (add): $($d.addToExcludeStamps -join ', ')"
    }
    if ($d.reason.Count -gt 0) {
        foreach ($r in $d.reason) { $diffLines += "    reason: $r" }
    }
    $diffLines += ""
}

[PSCustomObject]@{
    deltas     = $deltas
    diffText   = ($diffLines -join "`n")
    stampCount = $NewStamps.Count
    pipelines  = @($prodPipelines.Keys | Sort-Object)
}
