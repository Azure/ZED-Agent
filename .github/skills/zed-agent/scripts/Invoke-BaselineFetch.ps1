<#
.SYNOPSIS
    L-12: Auto-fetches the prior-run baseline at release setup time so the release
    owner specifies only deltas rather than reconstructing whole parameter sets.

.DESCRIPTION
    At release setup, fetches the most recent successful production run per pipeline
    using Read-PriorRun.ps1 and the L-17 baseline-union helper (Get-PriorRunBaseline.ps1).
    Stores the result as the baseline so the owner only needs to specify changes.

    Filters: only 'succeeded' runs count. Cancelled/failed runs are excluded per L-17.

.PARAMETER Organization
    ADO organization name.

.PARAMETER Project
    ADO project name.

.PARAMETER PipelineCatalogPath
    Path to pipeline-catalog.json.

.PARAMETER OutputPath
    Path where the baseline JSON will be written.

.PARAMETER FetchCallback
    Optional scriptblock to mock Read-PriorRun.ps1 calls in tests.
    Signature: -PipelineId <id> -Top <n> -ResultFilter <filter>
    Returns: array of run objects.

.OUTPUTS
    PSCustomObject with per-pipeline baseline data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [string]$PipelineCatalogPath = (Join-Path $PSScriptRoot '..\pipeline-catalog.json'),
    [Parameter(Mandatory)][string]$OutputPath,
    [scriptblock]$FetchCallback = $null
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PipelineCatalogPath)) { throw "pipeline-catalog.json not found at $PipelineCatalogPath" }

$catalog = Get-Content $PipelineCatalogPath -Raw | ConvertFrom-Json

# Collect all production pipeline IDs
$pipelineIds = @{}
if ($catalog.production) {
    foreach ($p in $catalog.production.PSObject.Properties) {
        if ($p.Value.PSObject.Properties['id']) {
            $pipelineIds[$p.Name] = [int]$p.Value.id
        }
    }
}

if ($pipelineIds.Count -eq 0) {
    Write-Warning "L-12: No production pipelines found in catalog. Baseline will be empty."
    $emptyBaseline = [PSCustomObject]@{
        pipelines  = @{}
        fetchedAt  = (Get-Date).ToUniversalTime().ToString('o')
        pipelineCount = 0
    }
    $emptyBaseline | ConvertTo-Json -Depth 10 | Set-Content $OutputPath -Encoding UTF8
    return $emptyBaseline
}

# Fetch runs per pipeline
$baselines = @{}
foreach ($key in $pipelineIds.Keys) {
    $pipelineId = $pipelineIds[$key]
    $runs = @()

    if ($FetchCallback) {
        $runs = @(& $FetchCallback -PipelineId $pipelineId -Top 3 -ResultFilter 'succeeded')
    } else {
        $readPriorRun = Join-Path $PSScriptRoot 'Read-PriorRun.ps1'
        $runs = @(& $readPriorRun -Organization $Organization -Project $Project `
            -PipelineId $pipelineId -Top 3 -ResultFilter 'succeeded')
    }

    # L-17: exclude cancelled/failed runs
    $validRuns = @($runs | Where-Object { $_.result -eq 'succeeded' -or [string]::IsNullOrEmpty($_.result) })

    $latestRun = $validRuns | Select-Object -First 1

    $baselines[$key] = [PSCustomObject]@{
        pipelineId         = $pipelineId
        latestRunId        = if ($latestRun) { $latestRun.runId } else { $null }
        latestRunUrl       = if ($latestRun) { $latestRun.runUrl } else { $null }
        finishedAt         = if ($latestRun) { $latestRun.finishedAt } else { $null }
        result             = if ($latestRun) { $latestRun.result } else { 'no-valid-runs' }
        templateParameters = if ($latestRun) { $latestRun.templateParameters } else { @{} }
        validRunCount      = $validRuns.Count
        totalRunsFetched   = $runs.Count
    }
}

$baseline = [PSCustomObject]@{
    pipelines     = $baselines
    fetchedAt     = (Get-Date).ToUniversalTime().ToString('o')
    pipelineCount = $pipelineIds.Count
}

# Persist baseline
$baseline | ConvertTo-Json -Depth 10 | Set-Content $OutputPath -Encoding UTF8

return $baseline
