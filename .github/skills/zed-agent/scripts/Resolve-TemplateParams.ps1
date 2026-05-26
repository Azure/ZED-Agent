<#
.SYNOPSIS
    Substitutes reserved {{...}} tokens in a pipeline's templateParameters
    map using inventory + routing data, filtering stamps/regions by the
    pipeline's clusterType when canaryRouting/productionRouting mode is
    "cluster-type". Refuses to return a map that mixes stamps across cluster
    types.

.DESCRIPTION
    Single point of truth for token substitution. Moves what used to be
    agent-prose ("filter by entry.clusterType when mode == cluster-type")
    into testable code. Called by Invoke-PipelineDryRun.ps1 before queueing
    a real ADO run, and re-used by Step 15 at real-release time.

    Reserved tokens recognised:
      {{currentBranch}}                         - caller passes short branch name
      {{canaryStamps}}, {{canaryRegions}}       - from inventory.canary, filtered by clusterType
      {{pubStamps}},  {{pubRegions}}            - from inventory.production.Public,  filtered by clusterType
      {{ffStamps}},   {{ffRegions}}             - from inventory.production.Fairfax, filtered by clusterType
      {{mcStamps}},   {{mcRegions}}             - from inventory.production.Mooncake, filtered by clusterType
      {{usnatStamps}},{{usnatRegions}}          - from inventory.production.USNat,   filtered by clusterType
      {{ussecStamps}},{{ussecRegions}}          - from inventory.production.USSec,   filtered by clusterType
      {{excludeStamps}}                         - always "" at dry-run / setup time
      {{sdpType}}                               - "Express" at dry-run; caller may override
      {{validateOnly}}                          - "true"    at dry-run; caller may override

    Cluster-type contamination assertion:
      When the pipeline's scope-routing.mode == "cluster-type", every stamp
      that survives substitution into any token MUST have a clusterType that
      equals the pipeline's clusterType. Otherwise the function throws
      "CLUSTER_TYPE_CONTAMINATION: <stampName>(<stampClusterType>) does not
      belong in <pipelineKey>(<pipelineClusterType>)" with the full list.

.PARAMETER PipelineKey
    The canary or production pipeline key (e.g. PROT-PROD-SFMC).

.PARAMETER Scope
    'canary' | 'production'. Selects which routing block and which inventory
    block to read.

.PARAMETER CurrentBranch
    Short branch name to substitute into {{currentBranch}}.

.PARAMETER ServiceConfigPath
    Optional override; defaults to .github/skills/zed-agent/service-config.json.

.PARAMETER PipelineCatalogPath
    Optional override; defaults to .github/skills/zed-agent/pipeline-catalog.json.

.PARAMETER DryRun
    When set, {{excludeStamps}} is forced to "" regardless of any future
    real-release filter logic. Default $true (this script is currently used
    only by dry-run + setup-service).

.OUTPUTS
    PSCustomObject:
      templateParameters = @{ <name> = <value>; ... }   # substituted map
      tokensSubstituted  = @("{{canaryStamps}}", ...)
      filteredStamps     = @(<stampName>, ...)          # stamps that survived clusterType filter
      droppedByFilter    = @(<stampName>, ...)          # filtered OUT due to clusterType mismatch (informational)
      diagnostics        = @{ pipelineClusterType, routingMode, stampStyle }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PipelineKey,
    [Parameter(Mandatory = $true)][ValidateSet('canary','production')][string]$Scope,
    [Parameter(Mandatory = $true)][string]$CurrentBranch,
    [string]$ServiceConfigPath,
    [string]$PipelineCatalogPath,
    [bool]  $DryRun = $true
)

$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\')).Path
if (-not $ServiceConfigPath)   { $ServiceConfigPath   = Join-Path $repoRoot '.github\skills\zed-agent\service-config.json' }
if (-not $PipelineCatalogPath) { $PipelineCatalogPath = Join-Path $repoRoot '.github\skills\zed-agent\pipeline-catalog.json' }

if (-not (Test-Path $ServiceConfigPath))   { throw "service-config.json not found at $ServiceConfigPath" }
if (-not (Test-Path $PipelineCatalogPath)) { throw "pipeline-catalog.json not found at $PipelineCatalogPath" }

$cfg = Get-Content $ServiceConfigPath   -Raw | ConvertFrom-Json
$cat = Get-Content $PipelineCatalogPath -Raw | ConvertFrom-Json

# ── Resolve the pipeline entry ────────────────────────────────────────
$scopeBlock = $cat.$Scope
if (-not $scopeBlock -or -not $scopeBlock.$PipelineKey) {
    throw "Pipeline '$PipelineKey' not found under pipeline-catalog.json -> $Scope.*"
}
$entry = $scopeBlock.$PipelineKey

# Routing block lives at catalog.canaryRouting / catalog.productionRouting.
$routingProp = if ($Scope -eq 'canary') { 'canaryRouting' } else { 'productionRouting' }
$routing     = $cat.$routingProp
$routingMode = if ($routing -and $routing.mode) { "$($routing.mode)".ToLowerInvariant() } else { 'static' }

$pipelineCt = $null
if ($entry.PSObject.Properties['clusterType'] -and $entry.clusterType) {
    $pipelineCt = "$($entry.clusterType)".ToLowerInvariant()
}

if ($routingMode -eq 'cluster-type' -and -not $pipelineCt) {
    throw "Pipeline '$PipelineKey' has $routingProp.mode='cluster-type' but no clusterType set under $Scope.$PipelineKey. Run 'setup-service group 4.2' to declare it."
}

# ── Build the per-scope inventory view (already filtered by clusterType) ──
$script:__droppedAcc = New-Object System.Collections.Generic.List[object]

function Get-FilteredStamps {
    param($Stamps, [string]$PipelineCt, [string]$Mode)
    if (-not $Stamps) { return @() }
    if ($Mode -ne 'cluster-type') { return @($Stamps) }
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Stamps) {
        $sct = $null
        if ($s.PSObject.Properties['clusterType'] -and $s.clusterType) {
            $sct = "$($s.clusterType)".ToLowerInvariant()
        }
        if (-not $sct) {
            throw "INVENTORY_MISSING_CLUSTERTYPE: stamp '$($s.stampName)' has no clusterType in inventory but routing mode='cluster-type'. Re-run 'setup-service group 4.9' to refresh, then group 4.6/4.7."
        }
        if ($sct -eq $PipelineCt) { $kept.Add($s) }
        else                      { $script:__droppedAcc.Add($s) }
    }
    return $kept.ToArray()
}

# Canary stamps live under inventory.canary.stamps regardless of scope (the
# token names canaryStamps/canaryRegions still resolve from canary inventory
# even inside production pipelines — that's how the agent expresses "deploy
# to canary regions first" in production-pipeline templateParameters).
$canaryStampsAll = @()
if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps) {
    $canaryStampsAll = @($cfg.inventory.canary.stamps)
}
$canaryStampsKept = @(Get-FilteredStamps -Stamps $canaryStampsAll -PipelineCt $pipelineCt -Mode $routingMode)

# Per-cloud production stamps.
function Get-CloudInventory {
    param([string]$Cloud)
    if (-not $cfg.inventory -or -not $cfg.inventory.production) { return $null }
    $blk = $cfg.inventory.production.$Cloud
    if (-not $blk -or ($blk.PSObject.Properties['skipped'] -and $blk.skipped)) { return $null }
    return $blk
}

$cloudMap = @{
    pub   = 'Public'
    ff    = 'Fairfax'
    mc    = 'Mooncake'
    usnat = 'USNat'
    ussec = 'USSec'
}

$prodKept = @{}   # prefix -> kept stamps[]
foreach ($prefix in $cloudMap.Keys) {
    $cloudName = $cloudMap[$prefix]
    $blk = Get-CloudInventory -Cloud $cloudName
    if (-not $blk -or -not $blk.stamps) { $prodKept[$prefix] = @(); continue }
    $prodKept[$prefix] = @(Get-FilteredStamps -Stamps $blk.stamps -PipelineCt $pipelineCt -Mode $routingMode)
}

# ── Token table ────────────────────────────────────────────────────────
function Join-Stamps    { param($s) ($s | ForEach-Object { $_.stampName }) -join ',' }
function Join-Regions   { param($s) ($s | ForEach-Object { $_.region    } | Select-Object -Unique) -join ',' }

$tokenTable = @{
    '{{currentBranch}}'  = $CurrentBranch
    '{{canaryStamps}}'   = Join-Stamps  $canaryStampsKept
    '{{canaryRegions}}'  = Join-Regions $canaryStampsKept
    '{{excludeStamps}}'  = ''
    '{{sdpType}}'        = 'Express'
    '{{validateOnly}}'   = 'true'
}
foreach ($prefix in $cloudMap.Keys) {
    $tokenTable["{{${prefix}Stamps}}"]  = Join-Stamps  $prodKept[$prefix]
    $tokenTable["{{${prefix}Regions}}"] = Join-Regions $prodKept[$prefix]
}

# ── Substitute into entry.templateParameters ──────────────────────────
$substituted     = @{}
$tokensUsed      = New-Object System.Collections.Generic.HashSet[string]
$stampsEmitted   = New-Object System.Collections.Generic.HashSet[string]

foreach ($p in $entry.templateParameters.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [string] -and $tokenTable.ContainsKey($v)) {
        [void]$tokensUsed.Add($v)
        $v = $tokenTable[$v]
        # Track which stamps actually went into the wire format so the
        # contamination assert has something to verify against.
        if ($v -and ($p.Name -match 'stamp' -or $p.Name -match 'Stamp')) {
            foreach ($name in ($v -split ',')) {
                $n = $name.Trim()
                if ($n) { [void]$stampsEmitted.Add($n.ToLowerInvariant()) }
            }
        }
    }
    $substituted[$p.Name] = $v
}

# ── Contamination assert (cluster-type mode only) ─────────────────────
if ($routingMode -eq 'cluster-type' -and $stampsEmitted.Count -gt 0) {
    $allStamps = @($canaryStampsAll) + @(foreach ($k in $cloudMap.Keys) {
        $blk = Get-CloudInventory -Cloud $cloudMap[$k]
        if ($blk -and $blk.stamps) { @($blk.stamps) }
    })
    $byName = @{}
    foreach ($s in $allStamps) {
        if ($s.stampName) { $byName["$($s.stampName)".ToLowerInvariant()] = $s }
    }
    $contam = @()
    foreach ($emitted in $stampsEmitted) {
        $row = $byName[$emitted]
        if (-not $row) { continue }  # unknown-to-inventory stamps are caught elsewhere
        $sct = if ($row.PSObject.Properties['clusterType'] -and $row.clusterType) {
            "$($row.clusterType)".ToLowerInvariant()
        } else { $null }
        if ($sct -ne $pipelineCt) {
            $contam += "$emitted(clusterType=$sct) does not belong in $PipelineKey(clusterType=$pipelineCt)"
        }
    }
    if ($contam.Count -gt 0) {
        throw "CLUSTER_TYPE_CONTAMINATION: $($contam -join '; ')"
    }
}

return [PSCustomObject]@{
    templateParameters = $substituted
    tokensSubstituted  = @($tokensUsed)
    filteredStamps     = @(@($canaryStampsKept) + @(foreach ($k in $cloudMap.Keys) { $prodKept[$k] }) | Where-Object { $_ } | ForEach-Object { $_.stampName })
    droppedByFilter    = @($script:__droppedAcc | Where-Object { $_ } | ForEach-Object { $_.stampName })
    diagnostics        = @{
        pipelineClusterType = $pipelineCt
        routingMode         = $routingMode
        scope               = $Scope
    }
}
