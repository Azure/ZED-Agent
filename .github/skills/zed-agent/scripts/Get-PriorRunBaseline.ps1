<#
.SYNOPSIS
    L-17: Build a production baseline from the union of all valid prior-release runs.

.DESCRIPTION
    A single prior run is not a complete production baseline because releases may
    use continuation runs. This script extends Read-PriorRun.ps1 by querying
    multiple runs per pipeline and building the union of their parameters.

    CRITICAL: Cancelled or failed runs are NOT evidence that a geography deployed.
    Only 'succeeded' and 'inProgress' runs contribute to the baseline.

.PARAMETER Organization
    ADO organization.

.PARAMETER Project
    ADO project.

.PARAMETER PipelineIds
    Hashtable keyed by pipeline key, values are pipeline definition IDs.

.PARAMETER MaxRunsPerPipeline
    Maximum runs to fetch per pipeline (default 10 — enough for continuation runs).

.OUTPUTS
    Array of PSCustomObject with: pipelineKey, pipelineId, result, regions (union),
    templateParameters (from most recent valid run), contributingRunIds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][hashtable]$PipelineIds,
    [int]$MaxRunsPerPipeline = 10
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$readPriorRun = Join-Path $scriptDir 'Read-PriorRun.ps1'

$baseline = @()

foreach ($key in $PipelineIds.Keys) {
    $pipelineId = $PipelineIds[$key]

    # Fetch runs with 'any' result so we can filter ourselves
    $runs = & $readPriorRun -Organization $Organization -Project $Project `
        -PipelineId $pipelineId -Top $MaxRunsPerPipeline -ResultFilter 'any'

    # L-17 enforcement: only succeeded or inProgress runs are valid baseline evidence
    $validRuns = @($runs | Where-Object {
        $_.result -in @('succeeded', $null) -or
        ($_.result -eq 'inProgress') -or
        ([string]::IsNullOrEmpty($_.result))  # still-active runs have no result
    })

    $cancelledOrFailed = @($runs | Where-Object {
        $_.result -in @('canceled', 'failed')
    })

    if ($cancelledOrFailed.Count -gt 0) {
        Write-Verbose "L-17: Excluded $($cancelledOrFailed.Count) cancelled/failed runs for pipeline $key (IDs: $($cancelledOrFailed.runId -join ', '))"
    }

    # Build union of PubRegions from all valid runs
    $unionRegions = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $contributingRunIds = @()

    foreach ($run in $validRuns) {
        $pubRegions = $run.templateParameters['PubRegions']
        if ($pubRegions) {
            $v = $pubRegions.Trim()
            if ($v -match '^regions\((.+)\)$') { $v = $Matches[1] }
            $regions = @($v -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            foreach ($r in $regions) { [void]$unionRegions.Add($r) }
        }
        $contributingRunIds += $run.runId
    }

    # Use the most recent valid run's template parameters as the base
    $latestValid = $validRuns | Select-Object -First 1
    $templateParams = if ($latestValid) { $latestValid.templateParameters } else { @{} }

    $baseline += [PSCustomObject]@{
        pipelineKey        = $key
        pipelineId         = $pipelineId
        result             = if ($latestValid) { $latestValid.result } else { 'no-valid-runs' }
        regions            = @($unionRegions | Sort-Object)
        templateParameters = $templateParams
        contributingRunIds = $contributingRunIds
        excludedRunCount   = $cancelledOrFailed.Count
    }
}

return ,$baseline
