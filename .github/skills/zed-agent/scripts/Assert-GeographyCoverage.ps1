<#
.SYNOPSIS
    L-16/L-17 geography coverage gate — blocks rollout when the union of all
    pipeline parameters does not cover every expected geography.

.DESCRIPTION
    Computes per-service: expected unique geographies (from AzureServiceConfig
    via Get-RegionMapping.ps1), each pipeline's covered geography set (from
    resolved parameters), the union, overlaps, and MISSING set.

    Persists the full breakdown into release state (via Update-ReleaseState.ps1)
    so it is auditable after the fact.

    THROWS when missing.Count > 0, naming every missing geography and which
    pipeline(s) should have covered it.

.PARAMETER PipelineParams
    Hashtable keyed by pipeline key, each value a hashtable of that pipeline's
    resolved template parameters. Every parameter carrying the `Regions` facet
    (discovered generically — `<Partition>Regions` or a flat `Regions`) is unioned
    to compute coverage; values may be a regions(...) string or a
    semicolon/comma-separated region list.

.PARAMETER ServiceConfigPath
    Path to service-config.json. Used to call Get-RegionMapping.ps1.

.PARAMETER PipelineCatalogPath
    Path to pipeline-catalog.json. Used to read pipeline-to-clusterType mapping
    for determining which pipeline SHOULD cover which geographies.

.PARAMETER ReleaseId
    Release id for persisting coverage audit into state.

.PARAMETER ExcludeRegions
    Regions excluded by CCOA or other policy — subtracted from expected set.

.PARAMETER PriorRunsBaseline
    Optional array of prior run objects (from Read-PriorRun.ps1 or union helper).
    Each must have: pipelineKey, result, templateParameters carrying at least one
    parameter with the `Regions` facet (e.g. `Regions`, `PubRegions`, `FFRegions`).
    L-17: only 'succeeded' or 'inProgress' runs are included in the baseline.

.PARAMETER SkipPersist
    When set, does not write to release state (for unit tests).

.OUTPUTS
    PSCustomObject with coverage breakdown (also persisted to state).
    Throws on missing geographies.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable]$PipelineParams,
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\service-config.json'),
    [string]$PipelineCatalogPath = (Join-Path $PSScriptRoot '..\pipeline-catalog.json'),
    [string]$ReleaseId,
    [string[]]$ExcludeRegions = @(),
    [array]$PriorRunsBaseline = @(),
    [switch]$SkipPersist
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'lib\YamlParamModel.ps1')

# ── 1. Build expected geography set from ASC (single source of truth) ──
$regionMappings = & (Join-Path $scriptDir 'Get-RegionMapping.ps1') `
    -ServiceConfigPath $ServiceConfigPath `
    -ExcludeRegions $ExcludeRegions

# Build expected set: unique Ev2Geography values from ASC
$expectedGeographies = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$geographyToRegions = @{}  # geography -> @(regionShortNames)

foreach ($r in $regionMappings) {
    $geo = $r.Ev2Geography
    if ([string]::IsNullOrWhiteSpace($geo)) { continue }
    [void]$expectedGeographies.Add($geo)
    if (-not $geographyToRegions.ContainsKey($geo)) {
        $geographyToRegions[$geo] = @()
    }
    $geographyToRegions[$geo] += $r.RegionShortName
}

# ── 2. Parse each pipeline's covered regions → geographies ──
# Helper: parse a regions-facet parameter value into an array of region short names
function Parse-RegionList {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    # Strip regions(...) wrapper
    $v = $Value.Trim()
    if ($v -match '^regions\((.+)\)$') { $v = $Matches[1] }
    # Split on comma or semicolon
    return @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Build region → geography lookup from ASC
$regionToGeography = @{}
foreach ($r in $regionMappings) {
    $regionToGeography[$r.RegionShortName.ToLower()] = $r.Ev2Geography
}

$pipelineCoverageMap = @{}  # pipelineKey -> @{ regions = @(); geographies = HashSet }
# Every regions-facet parameter actually seen, so the remedy can name the real
# parameter(s) for THIS service rather than assuming a fixed name.
$discoveredRegionParams = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$allCoveredGeographies = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($key in $PipelineParams.Keys) {
    $params = $PipelineParams[$key]
    # Service-agnostic: a service may partition regions across any number of
    # sovereign clouds under any naming, or use a single flat `Regions`.
    # Union every parameter that carries the `Regions` facet.
    $regions = @()
    $paramNames = if ($params -is [System.Collections.IDictionary]) { @($params.Keys) }
                  else { @($params.PSObject.Properties.Name) }
    foreach ($rn in @(Get-FacetParameterNames -ParameterNames $paramNames -Facet 'Regions')) {
        $regions += Parse-RegionList $params.$rn
        [void]$discoveredRegionParams.Add($rn)
    }
    $regions = @($regions | Select-Object -Unique)

    $geoSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($region in $regions) {
        $geo = $regionToGeography[$region.ToLower()]
        if ($geo) {
            [void]$geoSet.Add($geo)
            [void]$allCoveredGeographies.Add($geo)
        }
    }

    $pipelineCoverageMap[$key] = @{
        regions     = $regions
        geographies = $geoSet
    }
}

# ── 3. L-17: Incorporate prior runs baseline (union of valid runs only) ──
if ($PriorRunsBaseline.Count -gt 0) {
    foreach ($run in $PriorRunsBaseline) {
        # Only succeeded or inProgress runs count — cancelled/failed are NOT evidence
        $result = $run.result
        if ($result -and $result -notin @('succeeded', 'inProgress')) { continue }

        $pKey = $run.pipelineKey
        $regions = @()
        if ($run.templateParameters) {
            $tp = $run.templateParameters
            $tpNames = if ($tp -is [System.Collections.IDictionary]) { @($tp.Keys) }
                       else { @($tp.PSObject.Properties.Name) }
            foreach ($rn in @(Get-FacetParameterNames -ParameterNames $tpNames -Facet 'Regions')) {
                $regions += Parse-RegionList $tp.$rn
                [void]$discoveredRegionParams.Add($rn)
            }
        }
        foreach ($region in @($regions | Select-Object -Unique)) {
            $geo = $regionToGeography[$region.ToLower()]
            if ($geo) {
                [void]$allCoveredGeographies.Add($geo)
            }
        }
    }
}

# ── 4. Compute overlap and missing sets ──
$missing = [System.Collections.Generic.HashSet[string]]::new(
    $expectedGeographies, [System.StringComparer]::OrdinalIgnoreCase)
$missing.ExceptWith($allCoveredGeographies)

$overlap = @{}
$pipelineKeys = @($pipelineCoverageMap.Keys)
for ($i = 0; $i -lt $pipelineKeys.Count; $i++) {
    for ($j = $i + 1; $j -lt $pipelineKeys.Count; $j++) {
        $keyA = $pipelineKeys[$i]
        $keyB = $pipelineKeys[$j]
        $setA = $pipelineCoverageMap[$keyA].geographies
        $setB = $pipelineCoverageMap[$keyB].geographies
        $common = [System.Collections.Generic.HashSet[string]]::new(
            $setA, [System.StringComparer]::OrdinalIgnoreCase)
        $common.IntersectWith($setB)
        if ($common.Count -gt 0) {
            $overlap["$keyA|$keyB"] = @($common | Sort-Object)
        }
    }
}

# ── 5. Build coverage report ──
$perPipeline = @{}
foreach ($key in $pipelineCoverageMap.Keys) {
    $perPipeline[$key] = [PSCustomObject]@{
        regions     = @($pipelineCoverageMap[$key].regions | Sort-Object)
        geographies = @($pipelineCoverageMap[$key].geographies | Sort-Object)
    }
}

$coverageReport = [PSCustomObject]@{
    expectedGeographies = @($expectedGeographies | Sort-Object)
    expectedCount       = $expectedGeographies.Count
    coveredGeographies  = @($allCoveredGeographies | Sort-Object)
    coveredCount        = $allCoveredGeographies.Count
    missingGeographies  = @($missing | Sort-Object)
    missingCount        = $missing.Count
    perPipeline         = $perPipeline
    overlap             = $overlap
    computedAt          = (Get-Date).ToUniversalTime().ToString('o')
}

# ── 6. Persist to release state ──
if (-not $SkipPersist -and $ReleaseId) {
    try {
        $updateScript = Join-Path $scriptDir 'Update-ReleaseState.ps1'
        . $updateScript
        $stateProps = @{ geographyCoverage = $coverageReport }
        Update-ReleaseState -ReleaseId $ReleaseId -Action 'update-step' `
            -StepNumber 15 -StepStatus 'in-progress' `
            -StateProperties $stateProps `
            -AuditEntry (@{
                ts    = (Get-Date).ToUniversalTime().ToString('o')
                event = 'geography-coverage-check'
                expectedCount = $expectedGeographies.Count
                coveredCount  = $allCoveredGeographies.Count
                missingCount  = $missing.Count
            } | ConvertTo-Json -Compress)
    } catch {
        Write-Warning "Failed to persist geography coverage to state: $_"
    }
}

# ── 7. GATE: throw on missing geographies ──
if ($missing.Count -gt 0) {
    # Build an actionable message naming each missing geography and which regions it contains
    $details = @()
    foreach ($geo in ($missing | Sort-Object)) {
        $regions = $geographyToRegions[$geo]
        $regionList = if ($regions) { $regions -join ', ' } else { '(unknown regions)' }

        # Determine which pipeline(s) should cover it based on existing coverage patterns
        $details += "  - $geo (regions: $regionList)"
    }
    $detailBlock = $details -join "`n"

    $remedyParam = if ($discoveredRegionParams.Count -gt 0) {
        "'" + (@($discoveredRegionParams | Sort-Object) -join "' / '") + "'"
    } else {
        "the pipeline's regions parameter"
    }

    $msg = @(
        "GEOGRAPHY_COVERAGE_GAP: $($missing.Count) of $($expectedGeographies.Count) expected geographies are not covered by any pipeline.",
        "Missing geographies:",
        $detailBlock,
        "",
        "Covered: $($allCoveredGeographies.Count)/$($expectedGeographies.Count)",
        "",
        "Remedy: Add the missing regions to the appropriate pipeline's $remedyParam parameter.",
        "        Run Assert-GeographyCoverage.ps1 again to verify full coverage before proceeding."
    ) -join "`n"

    throw $msg
}

return $coverageReport
