<#
.SYNOPSIS
    L-22: Persists stage-map metadata from pipeline YAML introspection into release state
    and maps regions to stages when authoritative evidence is available.

.DESCRIPTION
    Uses Get-PipelineYamlIntrospection.ps1's stageMapName and stageMapVersion output
    (already extracted at lines 195-196 but never persisted). This script:
      1. Reads the introspection result and extracts stageMapName/stageMapVersion
      2. Persists them into release state for audit
      3. If a stage-map definition is provided, maps selected regions → stages
      4. If no authoritative stage-map is available, marks the mapping as 'unverified'

    NEVER infers rollout day from geography order — that is the explicit requirement.

.PARAMETER IntrospectionResult
    PSCustomObject from Get-PipelineYamlIntrospection.ps1 with stageMapName/stageMapVersion.

.PARAMETER SelectedRegions
    Array of region names selected for this rollout.

.PARAMETER StageMapDefinition
    Optional hashtable mapping region → stage. When absent, mapping is 'unverified'.

.PARAMETER PipelineKey
    Pipeline key for audit.

.OUTPUTS
    PSCustomObject with stageMap metadata and region→stage mapping (or unverified marker).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][PSCustomObject]$IntrospectionResult,
    [string[]]$SelectedRegions = @(),
    [hashtable]$StageMapDefinition = @{},
    [Parameter(Mandatory)][string]$PipelineKey
)

$ErrorActionPreference = 'Stop'

$stageMapName    = if ($IntrospectionResult.PSObject.Properties['stageMapName'])    { $IntrospectionResult.stageMapName }    else { $null }
$stageMapVersion = if ($IntrospectionResult.PSObject.Properties['stageMapVersion']) { $IntrospectionResult.stageMapVersion } else { $null }

# Determine verification status
$isVerified = ($null -ne $stageMapName -and $null -ne $stageMapVersion -and $StageMapDefinition.Count -gt 0)

# Map regions to stages if we have authoritative evidence
$regionStageMapping = @{}
$unmappedRegions    = @()

if ($isVerified -and $SelectedRegions.Count -gt 0) {
    foreach ($region in $SelectedRegions) {
        if ($StageMapDefinition.ContainsKey($region)) {
            $regionStageMapping[$region] = $StageMapDefinition[$region]
        } else {
            $unmappedRegions += $region
        }
    }
}

# Build status label
$status = if ($isVerified) {
    if ($unmappedRegions.Count -gt 0) { 'partially-verified' } else { 'verified' }
} else {
    'unverified'
}

[PSCustomObject]@{
    pipelineKey        = $PipelineKey
    stageMapName       = $stageMapName
    stageMapVersion    = $stageMapVersion
    status             = $status
    regionStageMapping = $regionStageMapping
    unmappedRegions    = $unmappedRegions
    isVerified         = $isVerified
    resolvedAt         = (Get-Date).ToUniversalTime().ToString('o')
}
