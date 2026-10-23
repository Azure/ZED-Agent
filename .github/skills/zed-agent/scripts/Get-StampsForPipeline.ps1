<#
.SYNOPSIS
    Returns the inventory stamps that a single pipeline key targets, given
    the current canary or production inventory. Layer 2 of capability B.

.DESCRIPTION
    Thin wrapper consumed by ZedAgent steps 5 (canary deploy), 7 (rollback),
    10 (roll-forward), and 15 (production rollout) so each step can render
    a precise "deploying to stamps: …" summary in its Teams message and
    rollout status output.

    Filtering rules:
      - cluster-type routing:
          * Read the pipeline's declared clusterType from pipeline-catalog
            ({scope}.{pipelineKey}.clusterType).
          * Return inventory stamps whose .clusterType matches.
          * If pipeline declares no clusterType but routing.mode is
            cluster-type, throw — the catalog is inconsistent.
      - static routing:
          * If pipeline declares clusterType, filter by it.
          * Otherwise return ALL inventory stamps for the scope (static
            pipelines that don't disambiguate by clusterType are assumed
            to target the whole fleet under that scope).

    Production scope additionally honors an optional -Cloud filter so Step
    15 can produce per-cloud breakdowns from a single inventory pull.

    Drift halt: this script does NOT re-throw on drift on its own. It relies
    on Resolve-PipelinesByClusterType.ps1 (already drift-halting) to have
    validated the scope before this script is called. Callers in discovery
    contexts may set -IgnoreDrift to suppress the underlying inventory's
    halt behavior, matching the resolver's contract.

.PARAMETER PipelineKey
    The key under {scope}.* in pipeline-catalog.json (e.g. "canary-sfmc",
    "prod-eap").

.PARAMETER Scope
    'canary' or 'production'.

.PARAMETER Cloud
    Optional production-scope cloud filter (matches ASC Clouds[].Name).

.PARAMETER CatalogPath / ServiceConfigPath / QueriesDir
    Override defaults (located via repo root from $PSScriptRoot, same as the
    resolver).

.PARAMETER IgnoreDrift
    Pass-through to Get-StampInventory (only via the inventory cache; the
    script itself never queries Kusto). Use only from setup-service.

.PARAMETER PreferCache
    Use cached inventory if fresh enough; default is live (-NoCache on the
    inventory script).

.OUTPUTS
    PSCustomObject:
      pipelineKey, scope, clusterType, cloud (filter), stamps[], drift[],
      inventorySources
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PipelineKey,
    [Parameter(Mandatory = $true)][ValidateSet('canary','production')][string]$Scope,
    [string]$Cloud,
    [string]$CatalogPath,
    [string]$ServiceConfigPath,
    [string]$QueriesDir,
    [switch]$IgnoreDrift,
    [switch]$PreferCache
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\')).Path
if (-not $CatalogPath)       { $CatalogPath       = Join-Path $repoRoot '.github\skills\zed-agent\pipeline-catalog.json' }
if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $repoRoot '.github\skills\zed-agent\service-config.json' }
if (-not $QueriesDir)        { $QueriesDir        = Join-Path $repoRoot '.github\skills\zed-agent\queries' }

if (-not (Test-Path $CatalogPath))       { throw "pipeline-catalog.json not found at $CatalogPath" }
if (-not (Test-Path $ServiceConfigPath)) { throw "service-config.json not found at $ServiceConfigPath" }

$catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json
$section = $catalog.$Scope
if (-not $section) { throw "pipeline-catalog.json has no '$Scope' block." }
if (-not $section.PSObject.Properties[$PipelineKey]) {
    throw "Pipeline key '$PipelineKey' not found under $Scope.* in pipeline-catalog.json."
}

$pipelineCT = $section.$PipelineKey.clusterType
$routingKey = "${Scope}Routing"
$routing    = $catalog.$routingKey
$mode       = if ($routing -and $routing.mode) { $routing.mode } else { 'static' }
if ($mode -eq 'cluster-type' -and -not $pipelineCT) {
    throw "$Scope.$PipelineKey is missing .clusterType — required when ${routingKey}.mode='cluster-type'. Run 'setup-service group 11'."
}

$invScript = Join-Path $PSScriptRoot 'Get-StampInventory.ps1'
if (-not (Test-Path $invScript)) { throw "Get-StampInventory.ps1 sibling script missing at $invScript." }
$invArgs = @{ Scope = $Scope; ServiceConfigPath = $ServiceConfigPath; QueriesDir = $QueriesDir }
if ($Cloud)       { $invArgs.Cloud       = $Cloud }
if ($PreferCache) { $invArgs.PreferCache = $true } else { $invArgs.NoCache = $true }
$inventory = & $invScript @invArgs

if (@($inventory.drift).Count -gt 0 -and -not $IgnoreDrift) {
    $driftLines = @($inventory.drift | ForEach-Object { " - $($_.stampName): $($_.reason)" }) -join "`n"
    throw "DRIFT_HALT: $Scope inventory has $(@($inventory.drift).Count) drift row(s); halt for owner approval / mitigation:`n$driftLines"
}

$stamps = if ($pipelineCT) {
    @($inventory.stamps | Where-Object { "$($_.clusterType)".ToLowerInvariant() -eq "$pipelineCT".ToLowerInvariant() })
} else {
    @($inventory.stamps)
}

[PSCustomObject]@{
    pipelineKey      = $PipelineKey
    scope            = $Scope
    clusterType      = $pipelineCT
    cloud            = $Cloud
    stamps           = $stamps
    drift            = @($inventory.drift)
    inventorySources = $inventory.sources
}
