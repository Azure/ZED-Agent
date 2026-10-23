<#
.SYNOPSIS
    Resolves the set of canary OR production pipeline keys that should be
    triggered for the current release, based on `{scope}Routing.mode` in
    pipeline-catalog.json.

.DESCRIPTION
    Single resolver consumed by:
      - Steps 5, 7, 10 in ZedAgent.agent.md (canary deploy / rollback / roll-forward)
      - Step 15 in ZedAgent.agent.md          (production rollout)
      - Phase 11.2 / 11.3 of setup-service     (dry-run fan-out)

    Routing modes (per pipeline-catalog.json):
      - mode = "static"        → return every key under {scope}.* with source="static".
                                  Attaches a best-effort `stamps`/`drift` view
                                  from Get-StampInventory for diagnostics, but
                                  drift is NEVER blocking in static mode.
      - mode = "cluster-type"  → call Get-StampInventory.ps1 -Scope {scope}
                                  (which runs the Kusto query for production,
                                  reads inventory.canary.stamps for canary,
                                  and joins both with AzureServiceConfig).
                                  Extract the live cluster-type SET from
                                  inventory.stamps[].clusterType; intersect
                                  with {scope}Routing.clusterTypeMap; return
                                  the resolved pipeline keys with
                                  source="kusto-resolved".

    Drift halt (Layer 2): if Get-StampInventory reports any drift rows in
    cluster-type mode (stamp name doesn't match grammar, serviceTag mismatch,
    layout unknown to ASC, shortName not in the resolved cloud, canary
    cloudHint mismatch), this script throws with prefix "DRIFT_HALT:" and the
    full drift list. Callers (Steps 5/7/10/15) must halt the step `failed` and
    surface the message to the owner via Teams. Pass -IgnoreDrift only from
    setup-service discovery contexts where the owner is still iterating.

    Cluster-type is a PIPELINE-level attribute, not a per-cloud one. A single
    production pipeline may push to multiple clouds (see ev2CloudCoverage.<key>)
    but its declared clusterType is the same across all of them — so the resolver
    runs once per scope, fans out at the pipeline level, not per cloud.

    Hard rules:
      - cluster-type mode + Kusto query failure  → throw (caller halts step `failed`).
      - cluster-type mode + empty live set       → throw (do not silently trigger nothing
                                                   or everything; surface to owner).
      - clusterTypeMap entry whose pipeline key
        is missing from {scope}.*                → warn and skip.
      - Pipeline declared under {scope}.* but
        whose declared clusterType is not in the
        live set                                 → omitted with reason="no live cluster type".

.PARAMETER Scope
    'canary' or 'production'.

.PARAMETER CatalogPath
    Path to pipeline-catalog.json. Defaults to .github/skills/zed-agent/pipeline-catalog.json
    relative to the script's repo root.

.PARAMETER ServiceConfigPath
    Path to service-config.json. Defaults next to the catalog.

.PARAMETER QueriesDir
    Folder containing .kql files. Defaults next to the catalog under queries/.

.OUTPUTS
    PSCustomObject:
      scope, mode,
      resolved          = @(@{ pipelineKey; clusterType; source; evidence })
      skipped           = @(@{ pipelineKey; clusterType; reason })
      liveClusterTypes  = @() (cluster-type mode only)
      queryRanAt        = ISO-8601 UTC | $null (static mode)
      queryDurationMs   = int            | $null
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('canary','production')][string]$Scope,
    [string]$CatalogPath,
    [string]$ServiceConfigPath,
    [string]$QueriesDir,
    # Layer 2: live stamp inventory is now the source of cluster-type evidence.
    # By default any drift detected by Get-StampInventory halts the resolver
    # with a non-empty $drift surfaced through the thrown error. Pass
    # -IgnoreDrift only from setup-service dry-runs / discovery contexts where
    # the owner is still iterating on inventory.canary or Kusto query shape.
    [switch]$IgnoreDrift,
    # Inventory is fetched live by default. Setup-service may pass -PreferCache
    # for hot loops; release steps must NOT pass it (we want live evidence).
    [switch]$PreferCache
)

$ErrorActionPreference = 'Stop'

# ── Locate config files ────────────────────────────────────────────────
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\') -ErrorAction SilentlyContinue
if (-not $CatalogPath)       { $CatalogPath       = Join-Path $repoRoot '.github/skills/zed-agent/pipeline-catalog.json' }
if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $repoRoot '.github/skills/zed-agent/service-config.json' }
if (-not $QueriesDir)        { $QueriesDir        = Join-Path $repoRoot '.github/skills/zed-agent/queries' }

if (-not (Test-Path $CatalogPath))       { throw "pipeline-catalog.json not found at $CatalogPath" }
if (-not (Test-Path $ServiceConfigPath)) { throw "service-config.json not found at $ServiceConfigPath" }

$catalog = Get-Content $CatalogPath       -Raw | ConvertFrom-Json
$config  = Get-Content $ServiceConfigPath -Raw | ConvertFrom-Json

$routingKey = "${Scope}Routing"
$routing    = $catalog.$routingKey
$section    = $catalog.$Scope

if (-not $section) { throw "pipeline-catalog.json has no '$Scope' block." }

$mode = if ($routing -and $routing.mode) { $routing.mode } else { 'static' }

# ── STATIC mode ────────────────────────────────────────────────────────
if ($mode -eq 'static') {
    $keys = @($section.PSObject.Properties.Name)
    $resolved = foreach ($k in $keys) {
        [PSCustomObject]@{
            pipelineKey = $k
            clusterType = if ($section.$k.clusterType) { $section.$k.clusterType } else { $null }
            source      = 'static'
            evidence    = $null
        }
    }
    # Best-effort inventory attach for Teams summaries & rollout diagnostics.
    # Static mode means owner opted out of cluster-type routing, so drift here
    # is informational, not blocking. Failures are swallowed.
    $stampList = @(); $driftList = @(); $invSrc = $null
    try {
        $invScript = Join-Path $PSScriptRoot 'Get-StampInventory.ps1'
        if (Test-Path $invScript) {
            $invArgs = @{ Scope = $Scope; ServiceConfigPath = $ServiceConfigPath; QueriesDir = $QueriesDir }
            if ($PreferCache) { $invArgs.PreferCache = $true }
            $inv = & $invScript @invArgs
            if ($inv) { $stampList = @($inv.stamps); $driftList = @($inv.drift); $invSrc = $inv.sources }
        }
    } catch { Write-Verbose "Static-mode inventory attach skipped: $($_.Exception.Message)" }

    return [PSCustomObject]@{
        scope            = $Scope
        mode             = 'static'
        resolved         = @($resolved)
        skipped          = @()
        liveClusterTypes = @()
        stamps           = $stampList
        drift            = $driftList
        inventorySources = $invSrc
        queryRanAt       = $null
        queryDurationMs  = $null
    }
}

# ── CLUSTER-TYPE mode ──────────────────────────────────────────────────
if ($mode -ne 'cluster-type') {
    throw "Unknown ${routingKey}.mode '$mode' — expected 'static' or 'cluster-type'."
}

# Layer 2: pull the authoritative stamp inventory. Get-StampInventory does
# the Kusto query for production, owner-curated lookup for canary, AND the
# ASC join + drift detection in one place. The resolver no longer queries
# Kusto directly — single source of truth.
$inventoryScript = Join-Path $PSScriptRoot 'Get-StampInventory.ps1'
if (-not (Test-Path $inventoryScript)) { throw "Get-StampInventory.ps1 sibling script missing at $inventoryScript." }

$invArgs = @{ Scope = $Scope; ServiceConfigPath = $ServiceConfigPath; QueriesDir = $QueriesDir }
if ($PreferCache) { $invArgs.PreferCache = $true } else { $invArgs.NoCache = $true }
$inventory = & $inventoryScript @invArgs
if (-not $inventory) { throw "Get-StampInventory.ps1 returned no result for scope='$Scope'." }

# Drift = hard halt unless explicitly overridden (setup-service discovery only).
if (@($inventory.drift).Count -gt 0 -and -not $IgnoreDrift) {
    $driftLines = @($inventory.drift | ForEach-Object { " - $($_.stampName): $($_.reason)" }) -join "`n"
    throw "DRIFT_HALT: $Scope inventory has $(@($inventory.drift).Count) drift row(s); halt for owner approval / mitigation:`n$driftLines"
}

# Extract live cluster types from the enriched inventory (already lowercased
# and deduplicated by Get-StampInventory).
$live = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($s in @($inventory.stamps)) {
    if ($s.clusterType) { [void]$live.Add("$($s.clusterType)".ToLowerInvariant()) }
}
$startedAt  = if ($inventory.kusto -and $inventory.kusto.ranAt) { [DateTime]::Parse($inventory.kusto.ranAt) } else { (Get-Date).ToUniversalTime() }
$durationMs = if ($inventory.kusto -and $inventory.kusto.durationMs) { [int]$inventory.kusto.durationMs } else { 0 }

if ($live.Count -eq 0) {
    throw "Inventory for scope='$Scope' produced 0 cluster types from $(@($inventory.stamps).Count) stamp(s). Refusing to silently trigger zero or all pipelines — investigate inventory.canary.stamps[].clusterType (canary) or kusto.production.clusterTypeExtraction (production)."
}

# ── Intersect with clusterTypeMap → pipeline keys ──────────────────────
$map = $routing.clusterTypeMap
if (-not $map) { throw "$routingKey.clusterTypeMap is missing — required when mode='cluster-type'." }

$wantKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$resolved = @()
$skipped  = @()

foreach ($ct in $live) {
    $mapped = $map.$ct
    if ($null -eq $mapped) {
        $skipped += [PSCustomObject]@{ pipelineKey = $null; clusterType = $ct; reason = 'cluster-type observed in Kusto but no clusterTypeMap entry' }
        continue
    }
    foreach ($k in @($mapped)) {
        if (-not $section.PSObject.Properties[$k]) {
            $skipped += [PSCustomObject]@{ pipelineKey = $k; clusterType = $ct; reason = "clusterTypeMap references key '$k' that is missing from $Scope.*" }
            continue
        }
        if ($wantKeys.Add($k)) {
            $resolved += [PSCustomObject]@{
                pipelineKey = $k
                clusterType = $ct
                source      = 'kusto-resolved'
                evidence    = [PSCustomObject]@{ liveClusterTypes = @($live); queryFile = $kustoCfg.queryFile; queryRanAt = $startedAt.ToUniversalTime().ToString('o') }
            }
        }
    }
}

# Pipelines declared under {scope}.* with a clusterType NOT in the live set are
# omitted with reason — that is the whole point of the resolver. Surface them
# in 'skipped' for owner visibility (e.g., wizard dry-run report).
foreach ($prop in $section.PSObject.Properties) {
    $k = $prop.Name
    if ($wantKeys.Contains($k)) { continue }
    $ct = $prop.Value.clusterType
    if ($ct) {
        $skipped += [PSCustomObject]@{ pipelineKey = $k; clusterType = $ct; reason = 'no live cluster type matched at query time' }
    }
}

return [PSCustomObject]@{
    scope            = $Scope
    mode             = 'cluster-type'
    resolved         = $resolved
    skipped          = $skipped
    liveClusterTypes = @($live)
    stamps           = @($inventory.stamps)
    drift            = @($inventory.drift)
    inventorySources = $inventory.sources
    queryRanAt       = $startedAt.ToUniversalTime().ToString('o')
    queryDurationMs  = $durationMs
}
