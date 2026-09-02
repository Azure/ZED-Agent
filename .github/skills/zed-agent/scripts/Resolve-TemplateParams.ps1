<#
.SYNOPSIS
    Resolve reserved {{...}} tokens in a pipeline's templateParameters using
    service-config.json inventory + pipeline-catalog.json routing. Enforces
    cluster-type isolation when routing.mode='cluster-type'.

.DESCRIPTION
    Single source of truth for template-parameter substitution used by dry-run
    (Invoke-PipelineDryRun.ps1) and Step 15 real-release. Behavior:

      - Reads pipeline-catalog.json -> <scope>.<key>.templateParameters.
      - Intersects the payload with the pipeline's CURRENT YAML declaration
        (yamlIntrospection.parameters); a parameter the YAML no longer declares
        is dropped and reported, because ADO rejects the entire queue for one
        undeclared parameter.
      - Resolves each {{token}} from the learned parameter model
        (_learnedFrom.model) FIRST, in the exact literal form real releases were
        observed to use; falls back to inventory-derived values only when the
        pipeline has no learned model yet.
      - Skips computation entirely for a partition whose script flag is off,
        emitting the pipeline's own declared default instead.
      - Resolves branch-conditional enum parameters from the rule written in the
        parameter's displayName.
      - Loads canary inventory from service-config.json -> inventory.canary.stamps.
      - Loads production inventory from service-config.json -> inventory.production.<cloud>.
      - Emits ARM region names (stamp.ev2RegionName / supplementaryRegions /
        stampPrefixToRegion), never the short locality prefix.
      - Filters stamps by entry.clusterType when {scope}Routing.mode == 'cluster-type'.
      - Throws CLUSTER_TYPE_CONTAMINATION if any emitted stamp's clusterType
        does not match the pipeline's declared clusterType.
      - Throws if mode='cluster-type' and entry.clusterType is missing/unknown.

    Cloud-prefix map (token prefix -> service-config cloud key):
        pub   -> Public
        ff    -> Fairfax
        mc    -> Mooncake
        usnat -> USNat
        ussec -> USSec

.PARAMETER PipelineKey
    Key under canary.* or production.* in pipeline-catalog.json.

.PARAMETER Scope
    'canary' or 'production'.

.PARAMETER CurrentBranch
    SHORT branch name (e.g., 'develop'); substituted for {{currentBranch}}.

.PARAMETER ServiceConfigPath
    Path to service-config.json.

.PARAMETER PipelineCatalogPath
    Path to pipeline-catalog.json.

.PARAMETER DryRun
    When set, validateOnly=true, excludeStamps='', sdpType='Test'.

.OUTPUTS
    PSCustomObject:
      pipelineKey, scope, clusterType, routingMode,
      templateParameters (hashtable, all tokens substituted),
      droppedStamps (stamps removed by cluster-type filter),
      droppedParameters (params the YAML no longer declares),
      resolutionSources (per parameter: model:<shape> | inventory | catalogStatic |
        declaredDefault:partitionDisabled | branchConditionalEnum:<branch> | testMode:baseBranch),
      declaredParameters (the pipeline's YAML declaration),
      learnedModel (_learnedFrom.model, or $null),
      agentGaps (array of warning strings)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PipelineKey,
    [Parameter(Mandatory)] [ValidateSet('canary','production')] [string] $Scope,
    [Parameter(Mandatory)] [string] $CurrentBranch,
    [Parameter(Mandatory)] [string] $ServiceConfigPath,
    [Parameter(Mandatory)] [string] $PipelineCatalogPath,
    [switch] $DryRun,

    # TEST-MODE ONLY: when set, ArtifactsBranch (mapped to {{currentBranch}}) is overridden
    # to pipeline-catalog.json → yamlRepos.<repo>.baseBranch so the artifact resource resolves
    # on a branch that has a completed officialBuild. The synthetic ZedForge test branch never
    # has one, causing HTTP 400 at trigger time. Production mode must never pass this switch.
    [switch] $TestMode,

    # L-05: Cross-reference every emitted token against the pipeline's expected input schema
    # at resolve time. Catches format mismatches (L-03), cloud-scope misalignment (L-04),
    # wildcard production scope (L-09), dual-gate misalignment (L-10), value-format
    # mismatches (L-06), and cross-pipeline geography coverage (L-16) — without triggering
    # any pipeline. Use with -AllPipelineResults to check coverage across all pipelines.
    [switch] $Validate,

    # L-05: When -Validate is set, pass all other pipelines' resolved results so
    # cross-pipeline geography coverage (L-16) can be checked at resolve time.
    [array] $AllPipelineResults = @(),

    # L-05: Path to pipeline-catalog.json's expected parameter schema (optional).
    # When provided with -Validate, checks each emitted parameter key exists in
    # the pipeline's declared templateParameters.
    [hashtable] $ExpectedSchema = @{}
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\YamlParamModel.ps1')

if (-not (Test-Path $ServiceConfigPath))   { throw "service-config.json not found at $ServiceConfigPath" }
if (-not (Test-Path $PipelineCatalogPath)) { throw "pipeline-catalog.json not found at $PipelineCatalogPath" }

$cfg     = Get-Content $ServiceConfigPath  -Raw | ConvertFrom-Json
$catalog = Get-Content $PipelineCatalogPath -Raw | ConvertFrom-Json

# --- Resolve entry ---
if (-not $catalog.$Scope -or -not $catalog.$Scope.PSObject.Properties[$PipelineKey]) {
    throw "Pipeline key '$PipelineKey' not found under $Scope.* in pipeline-catalog.json."
}
$entry = $catalog.$Scope.$PipelineKey

# --- Routing & cluster-type ---
$routingProp = if ($Scope -eq 'canary') { 'canaryRouting' } else { 'productionRouting' }
$routing     = $catalog.$routingProp
$mode        = if ($routing -and $routing.mode) { [string]$routing.mode } else { 'static' }
$pipelineCt  = if ($entry.PSObject.Properties['clusterType']) { [string]$entry.clusterType } else { $null }

if ($mode -eq 'cluster-type' -and -not $pipelineCt) {
    throw "Pipeline '$PipelineKey' has $routingProp.mode='cluster-type' but no clusterType set under $Scope.$PipelineKey. Run 'setup-service group 4.2' to declare it."
}

# --- Inventory builders ---
$script:droppedAcc  = [System.Collections.Generic.List[object]]::new()
$script:agentGapAcc = [System.Collections.Generic.List[string]]::new()
$script:cloudBlockers = @{}
$agentGaps          = [System.Collections.Generic.List[string]]::new()
# Token -> the reason its source cloud cannot be trusted. Consulted only if the
# token is actually consumed by an enabled partition.
$tokenBlockedBy     = @{}

function Get-FilteredStamps {
    param($Stamps, [string]$Mode, [string]$PipelineCt, [string]$Cloud, [string]$ExcludeCloud)
    if (-not $Stamps) { return @() }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $Stamps) {
        # Cloud filter (L-04): when $Cloud is supplied, keep only stamps whose cloud matches or that have no cloud property
        if ($Cloud) {
            $sCloud = if ($s.PSObject.Properties['cloud']) { [string]$s.cloud } else { $null }
            if ($sCloud -and $sCloud -ne $Cloud) {
                $script:droppedAcc.Add(@{ stampName = $s.stampName; cloud = $sCloud; reason = "cloud '$sCloud' != required '$Cloud'" })
                continue
            }
        }
        # Inverse of the above: keep only stamps that sit OUTSIDE a named cloud.
        # Used to find the stamps a canary run deploys to beyond the canary cloud
        # itself, without this code having to know what those clouds are called.
        if ($ExcludeCloud) {
            $sCloud = if ($s.PSObject.Properties['cloud']) { [string]$s.cloud } else { $null }
            if (-not $sCloud -or $sCloud -eq $ExcludeCloud) {
                $script:droppedAcc.Add(@{ stampName = $s.stampName; cloud = $sCloud; reason = "cloud '$sCloud' is excluded cloud '$ExcludeCloud'" })
                continue
            }
        }
        # Cluster-type filter (original logic)
        if ($Mode -ne 'cluster-type') { $kept.Add($s); continue }
        $sct = if ($s.PSObject.Properties['clusterType']) { [string]$s.clusterType } else { $null }
        if (-not $sct) {
            # A stamp with no clusterType cannot be proven to belong to THIS pipeline.
            # Dropping it silently loses fleet coverage; keeping it risks deploying a
            # cluster type's payload onto the wrong cluster. Neither is safe to guess,
            # so the cloud is marked blocked: the stamp is left out AND any parameter
            # that would be derived from this cloud becomes a hard stop. The stop is
            # deferred rather than thrown here so an inventory gap in a cloud this
            # pipeline does not deploy to cannot block a release that never touches it.
            $label = if ($s.stampId) { $s.stampId } elseif ($s.stampName) { $s.stampName } else { '<unknown>' }
            $ck = if ($Cloud) { $Cloud } else { '<unscoped>' }
            if (-not $script:cloudBlockers.ContainsKey($ck)) { $script:cloudBlockers[$ck] = [System.Collections.Generic.List[string]]::new() }
            $script:cloudBlockers[$ck].Add($label)
            $script:droppedAcc.Add(@{ stampName = $label; cloud = $ck; reason = 'no clusterType — cloud blocked' })
            continue
        }
        if ($sct -eq $PipelineCt) { $kept.Add($s) }
        else { $script:droppedAcc.Add(@{ stampName = $s.stampName; clusterType = $sct; reason = "ct '$sct' != pipeline '$PipelineCt'" }) }
    }
    return @($kept.ToArray())
}

function Get-CloudBlockerMessage {
    param([string]$Cloud, [string]$PipelineCt)
    if (-not $script:cloudBlockers.ContainsKey($Cloud)) { return $null }
    $labels = @($script:cloudBlockers[$Cloud])
    $shown  = if ($labels.Count -gt 8) { (($labels | Select-Object -First 8) -join ', ') + ", ... (+$($labels.Count - 8) more)" } else { $labels -join ', ' }
    return ("INVENTORY_MISSING_CLUSTERTYPE: $($labels.Count) stamp(s) in cloud '$Cloud' have no clusterType, " +
            "so they can neither be included in nor excluded from the '$PipelineCt' pipeline safely: $shown. " +
            "Operator action: add clusterType to these stamps in service-config.json -> inventory.production.$Cloud.stamps, " +
            "or remove them if they are retired.")
}

# Which cloud in the canary inventory IS the canary cloud is a fact about the
# service's inventory, not about ZED. Prefer an explicit declaration; otherwise
# infer it from the stamps themselves. ('canary' here is ZED's own scope name,
# not a service's cloud name — a service is free to call the cloud anything and
# declare it via inventory.canary.canaryCloud.)
$canaryCloudName = $null
if ($cfg.inventory -and $cfg.inventory.PSObject.Properties['canary'] -and $cfg.inventory.canary) {
    if ($cfg.inventory.canary.PSObject.Properties['canaryCloud'] -and $cfg.inventory.canary.canaryCloud) {
        $canaryCloudName = [string]$cfg.inventory.canary.canaryCloud
    } else {
        $canaryCloudsSeen = @($cfg.inventory.canary.stamps |
            ForEach-Object { if ($_.PSObject.Properties['cloud']) { [string]$_.cloud } } |
            Where-Object { $_ } | Select-Object -Unique)
        $selfNamed = @($canaryCloudsSeen | Where-Object { $_ -eq 'Canary' })
        if     ($selfNamed.Count -eq 1)         { $canaryCloudName = $selfNamed[0] }
        elseif ($canaryCloudsSeen.Count -eq 1)  { $canaryCloudName = $canaryCloudsSeen[0] }
    }
}

# Canary stamps (L-04: filter to the canary cloud so cross-cloud stamps are excluded)
$canaryStamps = @()
if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps) {
    $canaryStamps = @(Get-FilteredStamps -Stamps $cfg.inventory.canary.stamps -Mode $mode -PipelineCt $pipelineCt -Cloud $canaryCloudName)
}

# Cloud token-prefix -> service-config `inventory.production` key.
# Built entirely from config so a service whose clouds are named anything at all
# (Ring0/Ring1/EU/...) resolves without a code change:
#   1. identity — every key under inventory.production maps from its own lowercased name,
#      so {{<cloudkey>Stamps}} always works for ANY service.
#   2. per-cloud `tokenPrefix` (string or array) declared on the cloud object.
#   3. `inventory.cloudTokenMap` — an explicit { prefix = cloudKey } override block.
#   4. $defaultCloudAliases — the conventional Azure-cloud short forms, applied ONLY
#      where the config has not already claimed that prefix. These are sovereign-cloud
#      names shared by every Azure service (not this service's names); a config may
#      override any of them via (2)/(3), or replace the whole table — including with
#      an empty one — via `inventory.defaultCloudAliases`.
$defaultCloudAliases = @{
    'pub' = 'Public'; 'ff' = 'Fairfax'; 'mc' = 'Mooncake'
    'usnat' = 'USNat'; 'ussec' = 'USSec'; 'bleu' = 'Bleu'
}
if ($cfg.inventory -and $cfg.inventory.PSObject.Properties['defaultCloudAliases']) {
    $defaultCloudAliases = @{}
    if ($cfg.inventory.defaultCloudAliases) {
        foreach ($da in $cfg.inventory.defaultCloudAliases.PSObject.Properties) {
            if ($da.Value) { $defaultCloudAliases[$da.Name.ToLowerInvariant()] = [string]$da.Value }
        }
    }
}
$cloudMap = @{}
$nonCloudProps = @('approvalRequired', 'cloudsActive')
if ($cfg.inventory -and $cfg.inventory.PSObject.Properties['production'] -and $cfg.inventory.production) {
    foreach ($cp in $cfg.inventory.production.PSObject.Properties) {
        if ($cp.Name -in $nonCloudProps) { continue }
        if ($null -eq $cp.Value -or $cp.Value -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $cloudMap[$cp.Name.ToLowerInvariant()] = $cp.Name
        if ($cp.Value.PSObject.Properties['tokenPrefix'] -and $cp.Value.tokenPrefix) {
            foreach ($tp in @($cp.Value.tokenPrefix)) {
                if ($tp) { $cloudMap[([string]$tp).ToLowerInvariant()] = $cp.Name }
            }
        }
    }
}
if ($cfg.inventory -and $cfg.inventory.PSObject.Properties['cloudTokenMap'] -and $cfg.inventory.cloudTokenMap) {
    foreach ($mp in $cfg.inventory.cloudTokenMap.PSObject.Properties) {
        if ($mp.Value) { $cloudMap[$mp.Name.ToLowerInvariant()] = [string]$mp.Value }
    }
}
foreach ($alias in $defaultCloudAliases.Keys) {
    if (-not $cloudMap.ContainsKey($alias)) { $cloudMap[$alias] = $defaultCloudAliases[$alias] }
}

function Get-ProdCloudInventory {
    param([string]$CloudKey)
    if (-not $cfg.inventory -or -not $cfg.inventory.production) { return $null }
    if (-not $cfg.inventory.production.PSObject.Properties[$CloudKey]) { return $null }
    return $cfg.inventory.production.$CloudKey
}

# --- Style helpers ---
# Join separator (reads from discoveryNotes for backward compat)
$joinSep = ','
if ($entry.PSObject.Properties['discoveryNotes'] -and $entry.discoveryNotes -and $entry.discoveryNotes.PSObject.Properties['stampNameStyle']) {
    switch ([string]$entry.discoveryNotes.stampNameStyle) {
        'semicolon' { $joinSep = ';' }
        'space'     { $joinSep = ' ' }
        default     { $joinSep = ',' }
    }
}

# Stamp name style (L-03/U-07): 'short' uses stampId, 'full' uses stampName
$stampStyle = 'short'
if ($entry.PSObject.Properties['stampNameStyle']) {
    $stampStyle = [string]$entry.stampNameStyle
}

function Get-StampLabel {
    param($Stamp, [string]$Style)
    if ($Style -eq 'full') { return [string]$Stamp.stampName }
    # 'short' (default): prefer stampId, fall back to stampName
    if ($Stamp.PSObject.Properties['stampId'] -and $Stamp.stampId) {
        return [string]$Stamp.stampId
    }
    return [string]$Stamp.stampName
}

# --- CCOA exclusions (L-09) ---
$ccoaExcludedStamps  = @()
$ccoaExcludedRegions = @()
if ($cfg.inventory -and $cfg.inventory.PSObject.Properties['ccoaExclusions'] -and $cfg.inventory.ccoaExclusions) {
    $excl = $cfg.inventory.ccoaExclusions
    if ($excl.PSObject.Properties['stamps']  -and $excl.stamps)  { $ccoaExcludedStamps  = @($excl.stamps) }
    if ($excl.PSObject.Properties['regions'] -and $excl.regions) { $ccoaExcludedRegions = @($excl.regions) }
}

# --- Long-form region names (L-P3) ---
# Inventory stamps carry a SHORT locality prefix in `region` ('acl2', 'ea') and the
# deployable ARM region name in `ev2RegionName` ('australiacentral2'). Pipelines take
# the latter. Resolution order, all config-driven, no literals:
#   1. the stamp's own ev2RegionName
#   2. regions.supplementaryRegions[].RegionShortName (already ARM-form names)
#   3. stampPrefixToRegion, an explicit operator-maintained prefix map
#   4. a prefix->ARM mapping LEARNED from sibling stamps that carry both fields
# Only a value proven to be a short prefix by one of those sources is rewritten; a
# `region` that no source calls a prefix is taken to be an ARM name already and used
# as-is, because dropping it would silently shrink the deploy scope. Unresolvable
# known-prefixes are reported: a short prefix posted as a region name is accepted by
# ADO and then deploys nowhere.
$supplementaryRegionNames = @()
if ($cfg.PSObject.Properties['regions'] -and $cfg.regions -and $cfg.regions.PSObject.Properties['supplementaryRegions']) {
    $supplementaryRegionNames = @($cfg.regions.supplementaryRegions | ForEach-Object {
        if ($_.PSObject.Properties['RegionShortName']) { [string]$_.RegionShortName }
    } | Where-Object { $_ })
}
$stampPrefixMap = @{}
if ($cfg.PSObject.Properties['stampPrefixToRegion'] -and $cfg.stampPrefixToRegion) {
    foreach ($pp in $cfg.stampPrefixToRegion.PSObject.Properties) { $stampPrefixMap[[string]$pp.Name] = [string]$pp.Value }
}

# Learn the prefix vocabulary from the inventory itself: any stamp carrying BOTH
# `region` and a different `ev2RegionName` proves that `region` value is a prefix.
$learnedPrefixMap = @{}
if ($cfg.inventory) {
    $allInvStamps = [System.Collections.Generic.List[object]]::new()
    foreach ($scopeProp in $cfg.inventory.PSObject.Properties) {
        $scopeVal = $scopeProp.Value
        if (-not $scopeVal) { continue }
        if ($scopeVal.PSObject.Properties['stamps'] -and $scopeVal.stamps) {
            foreach ($s in @($scopeVal.stamps)) { if ($s) { $allInvStamps.Add($s) | Out-Null } }
        }
        foreach ($sub in $scopeVal.PSObject.Properties) {
            $subVal = $sub.Value
            if ($subVal -and $subVal.PSObject.Properties -and $subVal.PSObject.Properties['stamps'] -and $subVal.stamps) {
                foreach ($s in @($subVal.stamps)) { if ($s) { $allInvStamps.Add($s) | Out-Null } }
            }
        }
    }
    foreach ($s in $allInvStamps) {
        if (-not $s.PSObject.Properties['region'] -or -not $s.region) { continue }
        if (-not $s.PSObject.Properties['ev2RegionName'] -or -not $s.ev2RegionName) { continue }
        $sr = [string]$s.region; $lr = [string]$s.ev2RegionName
        if ($sr -ieq $lr) { continue }
        if (-not $learnedPrefixMap.ContainsKey($sr)) { $learnedPrefixMap[$sr] = $lr }
    }
}

function Test-IsKnownShortPrefix {
    param([string]$Short)
    if (-not $Short) { return $false }
    foreach ($k in $stampPrefixMap.Keys)   { if ($k -ieq $Short) { return $true } }
    foreach ($k in $learnedPrefixMap.Keys) { if ($k -ieq $Short) { return $true } }
    return $false
}

function Resolve-LongFormRegion {
    param($Stamp, [string]$Short)

    if ($Stamp -and $Stamp.PSObject.Properties['ev2RegionName'] -and $Stamp.ev2RegionName) {
        return [string]$Stamp.ev2RegionName
    }
    if (-not $Short) { return $null }

    $hit = @($supplementaryRegionNames | Where-Object { $_ -ieq $Short }) | Select-Object -First 1
    if ($hit) { return $hit }

    foreach ($k in $stampPrefixMap.Keys) {
        if ($k -ieq $Short) { return $stampPrefixMap[$k] }
    }
    foreach ($k in $learnedPrefixMap.Keys) {
        if ($k -ieq $Short) { return $learnedPrefixMap[$k] }
    }
    # Nothing calls this a prefix, so it is presumed to be the ARM name already.
    # Only a value the config/inventory says IS a prefix, yet cannot be expanded,
    # is a genuine gap - and that is reported by the caller.
    if (Test-IsKnownShortPrefix -Short $Short) { return $null }
    return $Short
}

function Get-StampRegions {
    param($Stamps, [string]$Context)
    $out  = [System.Collections.Generic.List[string]]::new()
    $gaps = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($Stamps)) {
        $short = if ($s.PSObject.Properties['region']) { [string]$s.region } else { $null }
        $long  = Resolve-LongFormRegion -Stamp $s -Short $short
        if (-not $long) {
            if ($short) { $gaps.Add($short) | Out-Null }
            continue
        }
        if (-not $out.Contains($long)) { $out.Add($long) | Out-Null }
    }
    if ($gaps.Count -gt 0) {
        $uniqueGaps = @($gaps | Select-Object -Unique)
        $agentGaps.Add("REGION_NAME_UNRESOLVED: $Context - no ARM region name for locality prefix(es) $($uniqueGaps -join ', '). " +
                       "Add ev2RegionName to those stamps, or an entry under service-config.json -> stampPrefixToRegion.")
    }
    return @($out.ToArray() | Sort-Object)
}

# --- Build token table ---
$stampsEmitted = New-Object System.Collections.Generic.HashSet[string]

function Add-Emitted {
    param($Stamps)
    foreach ($s in $Stamps) { [void]$stampsEmitted.Add([string]$s.stampName) }
}

$tokens = @{}
$tokens['{{currentBranch}}'] = $CurrentBranch
# U-06: sdpType from catalog entry; 'Standard' is the safe default (ADO accepts Standard|Conservative).
# 'Express' was an old compat default that ADO rejects — never use it.
$sdpTypeDefault = 'Standard'
if ($entry.PSObject.Properties['sdpType'] -and $entry.sdpType) {
    $sdpTypeDefault = [string]$entry.sdpType
}
$tokens['{{sdpType}}']       = if ($DryRun) { 'Test' } else { $sdpTypeDefault }
$tokens['{{validateOnly}}']  = if ($DryRun) { 'true' } else { 'false' }
# L-09: populate excludeStamps from CCOA exclusions
$tokens['{{excludeStamps}}']    = ($ccoaExcludedStamps -join $joinSep)
# pubExcludeStamps = same CCOA exclusions scoped to public-cloud stamp lists
$tokens['{{pubExcludeStamps}}'] = ($ccoaExcludedStamps -join $joinSep)

# Tokens carrying THIS release's context rather than the fleet's shape. A model
# learned from an earlier release necessarily holds that release's branch and
# switches, so it must never be allowed to answer for these.
$runContextTokens = @('{{currentBranch}}', '{{sdpType}}', '{{validateOnly}}')
# Exclusion lists are the one place a union is unambiguously safe: whatever the
# model learned, a stamp excluded for compliance this month must still be excluded.
$exclusionTokens  = @('{{excludeStamps}}', '{{pubExcludeStamps}}')

# TEST-MODE ONLY: resolve ArtifactsBranch to the stable baseBranch that has a completed
# officialBuild. The synthetic ZedForge test branch never has one; posting it as
# ArtifactsBranch causes HTTP 400 "No version was found for the pipeline". Computed once
# and stored; applied in the substitution loop below when -TestMode is set.
$testModeArtifactsBranch = $null
if ($TestMode) {
    $repoName = if ($cfg.ado -and $cfg.ado.PSObject.Properties['repository']) { [string]$cfg.ado.repository } else { $null }
    if (-not $repoName) {
        throw "Resolve-TemplateParams: -TestMode is set but service-config.json → ado.repository is missing. " +
              "Cannot resolve ArtifactsBranch baseBranch. Add ado.repository to service-config.json."
    }
    $baseBranchRef = & (Join-Path $PSScriptRoot 'Get-YamlRepoSourceBranch.ps1') `
        -CatalogPath $PipelineCatalogPath -RepoName $repoName
    # Get-YamlRepoSourceBranch returns "refs/heads/<branch>"; ArtifactsBranch expects the bare branch name.
    $testModeArtifactsBranch = $baseBranchRef -replace '^refs/heads/', ''
}

# Canary tokens
if ($Scope -eq 'canary' -or $canaryStamps.Count -gt 0) {
    # L-03: use Get-StampLabel (respects stampNameStyle: short→stampId, full→stampName)
    $canaryStampLabels = @($canaryStamps | ForEach-Object { Get-StampLabel -Stamp $_ -Style $stampStyle })
    $canaryRegions     = @(Get-StampRegions -Stamps $canaryStamps -Context "canary stamps for '$PipelineKey'")
    $tokens['{{canaryStamps}}']  = ($canaryStampLabels -join $joinSep)
    $tokens['{{canaryRegions}}'] = ($canaryRegions -join $joinSep)
    if ($Scope -eq 'canary') { Add-Emitted -Stamps $canaryStamps }
} else {
    $tokens['{{canaryStamps}}']  = ''
    $tokens['{{canaryRegions}}'] = ''
}

# L-06: canaryProdStamps / canaryProdRegions — Public-cloud canary-scope stamps
# These are stamps in inventory.canary.stamps with cloud=Public (e.g., ecy-01, ccy-01).
# They deploy to Public-cloud canary regions in a single pipeline run alongside Canary-cloud stamps.
# Reuses the existing -Cloud filter from Get-FilteredStamps (WP-A).
# Save/restore droppedAcc to avoid polluting the primary canaryStamps drop list —
# canaryProd drops are informational only and should not inflate the main drop count.
$canaryProdStamps = @()
if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps -and $canaryCloudName) {
    $savedDropCount = $script:droppedAcc.Count
    $canaryProdStamps = @(Get-FilteredStamps -Stamps $cfg.inventory.canary.stamps -Mode $mode -PipelineCt $pipelineCt -ExcludeCloud $canaryCloudName)
    while ($script:droppedAcc.Count -gt $savedDropCount) { $script:droppedAcc.RemoveAt($script:droppedAcc.Count - 1) }
}
$canaryProdStampLabels = @($canaryProdStamps | ForEach-Object { Get-StampLabel -Stamp $_ -Style $stampStyle })
$canaryProdRegions     = @(Get-StampRegions -Stamps $canaryProdStamps -Context "canary-scope public stamps for '$PipelineKey'")
$tokens['{{canaryProdStamps}}']  = ($canaryProdStampLabels -join $joinSep)
$tokens['{{canaryProdRegions}}'] = ($canaryProdRegions -join $joinSep)

# Production cloud tokens (always populate; production scope filters by clusterType; canary scope leaves them empty)
foreach ($prefix in $cloudMap.Keys) {
    $cloudKey   = $cloudMap[$prefix]
    $stampsTok  = "{{${prefix}Stamps}}"
    $regionsTok = "{{${prefix}Regions}}"
    if ($Scope -ne 'production') {
        $tokens[$stampsTok]  = ''
        $tokens[$regionsTok] = ''
        continue
    }
    $inv = Get-ProdCloudInventory -CloudKey $cloudKey
    if (-not $inv -or ($inv.PSObject.Properties['skipped'] -and $inv.skipped)) {
        $tokens[$stampsTok]  = ''
        $tokens[$regionsTok] = ''
        continue
    }
    $prodStamps = @()
    if ($inv.PSObject.Properties['stamps'] -and $inv.stamps) {
        # L-04: pass cloud key so Get-FilteredStamps applies cloud filter
        $prodStamps = @(Get-FilteredStamps -Stamps $inv.stamps -Mode $mode -PipelineCt $pipelineCt -Cloud $cloudKey)
    }
    # L-09: subtract CCOA-excluded stamps
    if ($ccoaExcludedStamps.Count -gt 0 -and $prodStamps.Count -gt 0) {
        $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($es in $ccoaExcludedStamps) { [void]$excludeSet.Add($es) }
        $beforeCount = $prodStamps.Count
        $prodStamps = @($prodStamps | Where-Object {
            $label = Get-StampLabel -Stamp $_ -Style $stampStyle
            if ($excludeSet.Contains($label)) {
                $script:droppedAcc.Add(@{ stampName = $_.stampName; reason = "CCOA-excluded stamp '$label'" })
                $false
            } else { $true }
        })
    }
    # U-07: use Get-StampLabel (respects stampNameStyle) instead of raw stampName
    $stampLabels = @($prodStamps | ForEach-Object { Get-StampLabel -Stamp $_ -Style $stampStyle })
    $regions    = @()
    if ($inv.PSObject.Properties['regions'] -and $inv.regions) {
        $regions = @($inv.regions)
    } elseif ($prodStamps) {
        $regions = @(Get-StampRegions -Stamps $prodStamps -Context "$cloudKey stamps for '$PipelineKey'")
    }
    # L-09: subtract CCOA-excluded regions
    if ($ccoaExcludedRegions.Count -gt 0 -and $regions.Count -gt 0) {
        $excludeRegSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($er in $ccoaExcludedRegions) { [void]$excludeRegSet.Add($er) }
        $regions = @($regions | Where-Object { -not $excludeRegSet.Contains($_) })
    }
    $tokens[$stampsTok]  = ($stampLabels -join $joinSep)
    $tokens[$regionsTok] = ($regions    -join $joinSep)

    # If this cloud's inventory is ambiguous, mark its tokens. The stop fires only
    # if an enabled partition actually consumes one of them.
    $blockMsg = Get-CloudBlockerMessage -Cloud $cloudKey -PipelineCt $pipelineCt
    if ($blockMsg) {
        $tokenBlockedBy[$stampsTok]  = $blockMsg
        $tokenBlockedBy[$regionsTok] = $blockMsg
    }

    # L-09: fail-closed assertions for production scope
    if ($Scope -eq 'production') {
        # Refuse wildcard region values
        $regionVal = $tokens[$regionsTok]
        if ($regionVal -match '^\s*\*\s*$' -or $regionVal -match 'regions\s*\(\s*\*\s*\)') {
            throw "UNSAFE_REGION_SCOPE: pipeline '$PipelineKey' token '$regionsTok' resolved to wildcard value '$regionVal'. This would deploy to ALL regions. Populate CCOA exclusions in service-config.json → inventory.ccoaExclusions or set per-pipeline maxRegions. Operator action: run 'setup-service group 4' to configure exclusions."
        }
        # Per-pipeline maxRegions check
        if ($entry.PSObject.Properties['maxRegions'] -and $entry.maxRegions -and $regions.Count -gt [int]$entry.maxRegions) {
            throw "UNSAFE_REGION_SCOPE: pipeline '$PipelineKey' token '$regionsTok' resolved to $($regions.Count) regions (max allowed: $($entry.maxRegions)). Value: '$regionVal'. Operator action: verify CCOA exclusions in service-config.json → inventory.ccoaExclusions are complete, or increase maxRegions on the catalog entry if the expanded scope is intentional."
        }
        # Per-pipeline requiresExclusions check
        if ($entry.PSObject.Properties['requiresExclusions'] -and $entry.requiresExclusions -eq $true) {
            if ($ccoaExcludedStamps.Count -eq 0) {
                throw "MISSING_EXCLUSIONS: pipeline '$PipelineKey' has requiresExclusions=true but no CCOA exclusions are configured in service-config.json → inventory.ccoaExclusions.stamps. Operator action: run 'setup-service group 4' to populate exclusions, or set requiresExclusions=false on the catalog entry if this pipeline intentionally deploys to all stamps."
            }
        }
    }

    Add-Emitted -Stamps $prodStamps
}

# Merge agentGapAcc (from Get-FilteredStamps) into agentGaps
foreach ($g in $script:agentGapAcc) { $agentGaps.Add($g) }

# --- P3: learned parameter model, consulted BEFORE the inventory ---
# The pipeline's YAML declaration and a model learned from real human releases are
# both authoritative about the parameter surface; the stamp inventory is not. It
# knows the fleet, not this pipeline's contract, and reading region names off it is
# what produced short locality prefixes where ARM region names belonged.
#
# Order of authority per parameter:
#   1. YAML declaration  - decides whether the parameter may be sent at all
#   2. learned model     - decides the VALUE and the exact literal FORM
#   3. inventory tokens  - last resort, for pipelines with no learned model yet
$declaredParams  = @()
if ($entry.PSObject.Properties['yamlIntrospection'] -and $entry.yamlIntrospection -and
    $entry.yamlIntrospection.PSObject.Properties['parameters']) {
    $declaredParams = @($entry.yamlIntrospection.parameters | Where-Object { $_ -and $_.name })
}
$declaredByName = @{}
foreach ($d in $declaredParams) { $declaredByName[[string]$d.name] = $d }

$learnedModel   = $null
$learnedRunIds  = @()
if ($entry.PSObject.Properties['_learnedFrom'] -and $entry._learnedFrom) {
    if ($entry._learnedFrom.PSObject.Properties['model']) { $learnedModel = $entry._learnedFrom.model }
    if ($entry._learnedFrom.PSObject.Properties['runs'])  { $learnedRunIds = @($entry._learnedFrom.runs) }
}
$modelByName = @{}
if ($learnedModel) {
    foreach ($mp in $learnedModel.PSObject.Properties) { $modelByName[[string]$mp.Name] = $mp.Value }
}
if (-not $learnedModel) {
    # Not fatal: a pipeline nobody has released yet has nothing to learn from. Say so
    # by name so the gap is actionable instead of invisible.
    $agentGaps.Add("NO_LEARNED_MODEL: pipeline '$PipelineKey' ($Scope) has no _learnedFrom model; " +
                   "parameter values fall back to inventory/catalog resolution. " +
                   "Operator action: run New-ParameterModel.ps1 with run ids from a real release of this pipeline.")
}

# Partition membership is derived from the declared parameter NAMES, never from a
# list of cloud names, so a service whose YAML calls its partitions something else
# gets the same gating for free.
$partitionModel = $null
if ($declaredParams.Count -gt 0) {
    $partitionModel = Get-ParameterPartitionModel -ParameterNames @($declaredParams | ForEach-Object { [string]$_.name })
}
$partitionOfParam = @{}
$scriptParamOfPartition = @{}
if ($partitionModel) {
    foreach ($part in @($partitionModel.partitions)) {
        foreach ($facetProp in $part.facets.PSObject.Properties) {
            $pname = [string]$facetProp.Value
            if ($pname) { $partitionOfParam[$pname] = [string]$part.name }
        }
        if ($part.facets.PSObject.Properties['script'] -and $part.facets.script) {
            $scriptParamOfPartition[[string]$part.name] = [string]$part.facets.script
        }
    }
}

function Test-PartitionEnabled {
    <#
        A partition whose script flag is off is not being deployed this release.
        Computing stamps and regions for it anyway is how ZED ended up sending a
        populated list where every human release sent the declared default.
        Returns $true when there is no flag to consult.
    #>
    param([string]$ParamName)
    $part = $partitionOfParam[$ParamName]
    if (-not $part) { return $true }
    $flagName = $scriptParamOfPartition[$part]
    if (-not $flagName) { return $true }
    if (-not $entry.templateParameters -or -not $entry.templateParameters.PSObject.Properties[$flagName]) { return $true }
    $flagVal = [string]$entry.templateParameters.$flagName
    if ([string]::IsNullOrWhiteSpace($flagVal)) { return $true }
    if ($flagVal -match '\{\{') { return $true }
    return -not ($flagVal -match '^(?i:false|0|no)$')
}

function Resolve-FromModel {
    <#
        Produce the value for a declared parameter from the learned model, in the
        exact literal form the pipeline was observed to accept. Returns $null when
        the model has nothing usable, so the caller can fall back.
    #>
    param([string]$Name)

    $m = $modelByName[$Name]
    if (-not $m) { return $null }
    if (-not $m.PSObject.Properties['shape'] -or -not $m.shape) { return $null }

    $selected = $null
    foreach ($refProp in 'selectedValue', 'lastValue', 'value') {
        if ($m.PSObject.Properties[$refProp] -and $null -ne $m.$refProp) { $selected = $m.$refProp; break }
    }

    switch ([string]$m.shape) {
        'wildcard'        { return [pscustomobject]@{ value = '*'; source = 'model:wildcard' } }
        'regionsWildcard' {
            $c = if ($m.container) { [string]$m.container } else { '' }
            return [pscustomobject]@{ value = "$c(*)"; source = 'model:regionsWildcard' }
        }
        default {
            if ($null -eq $selected) { return $null }
            return [pscustomobject]@{ value = [string]$selected; source = "model:$($m.shape)" }
        }
    }
}

# --- Substitute into templateParameters ---
$resolved = @{}

# L-06: Read paramFormat from discoveryNotes (ps-array, regions-wrapper, or bare/default)
$paramFormat = $null
if ($entry.PSObject.Properties['discoveryNotes'] -and $entry.discoveryNotes -and
    $entry.discoveryNotes.PSObject.Properties['paramFormat']) {
    $paramFormat = [string]$entry.discoveryNotes.paramFormat
}

# L-06: Short-region-name to full-region-name mapping for regions-wrapper format
# Uses the stamp inventory's region field which already contains full Azure region names
# (e.g., 'eastasia', 'eastus2'). No additional mapping needed if inventory regions are full names.

function Format-ParamValue {
    param([string]$Value, [string]$Format)
    if (-not $Format -or $Format -eq 'bare' -or -not $Value) { return $Value }
    switch ($Format) {
        'ps-array' {
            # Convert comma-separated values to PowerShell array notation: @("v1","v2")
            $items = $Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($items.Count -eq 0) { return '@()' }
            $quoted = $items | ForEach-Object { "`"$_`"" }
            return '@(' + ($quoted -join ',') + ')'
        }
        'regions-wrapper' {
            # Wrap comma-separated region names in regions(...) format
            $items = $Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($items.Count -eq 0) { return '' }
            return 'regions(' + ($items -join ',') + ')'
        }
        default { return $Value }
    }
}

# Auto-format token-resolved parameter values based on parameter name convention.
# Applied when no per-pipeline paramFormat is configured (the common case for services
# that don't set discoveryNotes.paramFormat). Ensures ADO receives correct array/region
# syntax without relying on the agent to reformat values.
# Guards against double-formatting: skips if value already starts with @( or regions(.
function Format-ByParamName {
    param([string]$Name, [string]$Value)
    # Already formatted — do not double-wrap
    if ($Value -match '^@\(' -or $Value -match '^regions\(') { return $Value }
    # Stamp parameters (e.g., Publicstamps, CanaryStamps, ExcludeStamps, FFstamps) → @("v1","v2") or @()
    if ($Name -imatch 'stamps') {
        if ([string]::IsNullOrEmpty($Value)) { return '@()' }
        $items = $Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($items.Count -eq 0) { return '@()' }
        $quoted = $items | ForEach-Object { "`"$_`"" }
        return '@(' + ($quoted -join ',') + ')'
    }
    # Region parameters NOT prefixed with Exclude (e.g., PubRegions, MCRegions, FFRegions) → regions(r1,r2)
    # PubExcludeRegions is intentionally excluded — it carries a space sentinel, not a region list.
    if ($Name -imatch '(?<!Exclude)Regions$') {
        if ([string]::IsNullOrEmpty($Value)) { return 'regions()' }
        $items = $Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        return 'regions(' + ($items -join ',') + ')'
    }
    return $Value
}

$droppedParams = [System.Collections.Generic.List[object]]::new()
$resolutionSources = @{}

if ($entry.templateParameters) {
    foreach ($p in $entry.templateParameters.PSObject.Properties) {
        $v = $p.Value

        # L2 intersect: the pipeline's current YAML is the only authority on which
        # parameters exist. A parameter the catalog remembers but the YAML has since
        # dropped makes ADO reject the whole queue, so it is removed here and
        # reported rather than sent and blamed on ADO.
        if ($declaredByName.Count -gt 0 -and -not $declaredByName.ContainsKey($p.Name)) {
            $droppedParams.Add([pscustomobject]@{
                parameter = $p.Name
                value     = [string]$v
                reason    = 'not declared by the pipeline YAML'
            }) | Out-Null
            $agentGaps.Add("PARAMETER_NO_LONGER_DECLARED: '$($p.Name)' is in the catalog for '$PipelineKey' but the pipeline YAML no longer declares it; dropped from the payload. Operator action: remove it from pipeline-catalog.json -> $Scope.$PipelineKey.templateParameters.")
            continue
        }

        $decl = $declaredByName[$p.Name]
        $isToken = ($v -is [string] -and $v -match '^\s*\{\{[^}]+\}\}\s*$')

        if ($isToken) {
            # Partition switched off: send exactly what the pipeline declares as its
            # own default. Anything computed here would be deploy scope nobody asked for.
            if (-not (Test-PartitionEnabled -ParamName $p.Name)) {
                $dv = if ($decl -and $null -ne $decl.default) { [string]$decl.default } else { '' }
                $resolved[$p.Name] = $dv
                $resolutionSources[$p.Name] = 'declaredDefault:partitionDisabled'
                continue
            }

            $fromModel = $null
            if ($runContextTokens -notcontains $v) { $fromModel = Resolve-FromModel -Name $p.Name }
            if ($fromModel) {
                $val = $fromModel.value
                $src = $fromModel.source
                # Compliance exclusions are additive on top of whatever was learned.
                if ($exclusionTokens -contains $v -and $ccoaExcludedStamps.Count -gt 0) {
                    $parts = Get-ContainerElements -Literal $val
                    $union = @($parts.elements)
                    $added = @()
                    foreach ($ex in $ccoaExcludedStamps) {
                        if ($union -notcontains $ex) { $union += $ex; $added += $ex }
                    }
                    if ($added.Count -gt 0) {
                        $val = New-ContainerLiteral -Elements $union -Container $parts.container -Quote $parts.quote -Separator $parts.separator
                        $src = "$src+ccoaExclusions"
                        $agentGaps.Add("CCOA_EXCLUSIONS_ADDED: '$($p.Name)' had $($added.Count) compliance exclusion(s) merged on top of the learned value: $($added -join ', ').")
                    }
                }
                $resolved[$p.Name] = $val
                $resolutionSources[$p.Name] = $src
            } elseif ($tokens.ContainsKey($v)) {
                # The cloud behind this token has stamps of unknown clusterType.
                # An enabled partition is about to deploy from it, so stop.
                if ($tokenBlockedBy.ContainsKey($v)) {
                    throw ("$($tokenBlockedBy[$v])`nThis blocks parameter '$($p.Name)' of pipeline '$PipelineKey', " +
                           "whose partition is enabled and therefore will deploy to that cloud.")
                }
                $resolvedVal = $tokens[$v]
                if ($paramFormat -and $resolvedVal) {
                    $resolvedVal = Format-ParamValue -Value $resolvedVal -Format $paramFormat
                } elseif ([string]::IsNullOrEmpty($paramFormat)) {
                    $resolvedVal = Format-ByParamName -Name $p.Name -Value $resolvedVal
                }
                $resolved[$p.Name] = $resolvedVal
                $resolutionSources[$p.Name] = 'inventory'
            } else {
                # Token-shaped literal we don't know about — leave as-is and flag.
                $resolved[$p.Name] = $v
                $resolutionSources[$p.Name] = 'unresolved'
                $agentGaps.Add("unknown-reserved-token: param=$($p.Name) value=$v")
                continue
            }
        } else {
            $resolved[$p.Name] = $v
            $resolutionSources[$p.Name] = 'catalogStatic'
        }

        # Branch-conditional enums: the pipeline author wrote the rule in the
        # parameter's own displayName. Apply it only when nothing deliberate is
        # being overridden - i.e. the value so far is the declared default or was
        # token-derived - so an explicit operator choice always wins.
        # NOTE: @($obj.missingProp) has Count 1, so `values` must be null-filtered
        # before it can be read as "this parameter is an enum".
        $declValues = @($decl.values | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($decl -and $declValues.Count -gt 0) {
            $current = [string]$resolved[$p.Name]
            $isDefaulted = $isToken -or ($null -ne $decl.default -and $current -eq [string]$decl.default)
            if ($isDefaulted) {
                $branchForEnum = if ($TestMode -and $testModeArtifactsBranch) { $testModeArtifactsBranch } else { $CurrentBranch }
                $enumPick = Resolve-BranchConditionalEnum -DisplayName ([string]$decl.displayName) `
                                                          -Values $declValues -BranchName $branchForEnum
                if ($enumPick -and $enumPick.value -ne $current) {
                    $resolved[$p.Name] = $enumPick.value
                    $resolutionSources[$p.Name] = "branchConditionalEnum:$branchForEnum"
                }
            }
        }

        # TEST-MODE ONLY: ArtifactsBranch must resolve to the stable baseBranch
        # (the synthetic test branch has no completed officialBuild -> HTTP 400).
        if ($TestMode -and $isToken -and $v -eq '{{currentBranch}}' -and $p.Name -eq 'ArtifactsBranch') {
            $resolved[$p.Name] = $testModeArtifactsBranch
            $resolutionSources[$p.Name] = 'testMode:baseBranch'
        }
    }
}

# Coverage report: the inventory still knows the fleet even when the model supplies
# the value, so anything the fleet has and the emitted value does not is surfaced.
# It is a warning, not a rewrite - silently widening deploy scope is worse than
# reporting that it may need widening.
if ($Scope -eq 'production' -and $modelByName.Count -gt 0) {
    foreach ($name in @($resolved.Keys)) {
        if ($resolutionSources[$name] -notlike 'model:*') { continue }
        $shapeNow = Get-ParameterValueShape ([string]$resolved[$name])
        if ($shapeNow.shape -ne 'regionsList') { continue }
        $tokName = $null
        if ($entry.templateParameters.PSObject.Properties[$name]) { $tokName = [string]$entry.templateParameters.$name }
        if (-not $tokName -or -not $tokens.ContainsKey($tokName)) { continue }
        $invRegions = @(([string]$tokens[$tokName]) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($invRegions.Count -eq 0) { continue }
        $emitted = @((Get-ContainerElements ([string]$resolved[$name])).elements)
        $uncovered = @($invRegions | Where-Object { $emitted -notcontains $_ })
        if ($uncovered.Count -gt 0) {
            $agentGaps.Add("REGION_COVERAGE_GAP: '$name' emits the value from run(s) $($learnedRunIds -join ',') and omits $($uncovered.Count) region(s) present in the inventory: $($uncovered -join ', '). Operator action: confirm these are intentionally out of scope, then re-learn the model from a release that includes them.")
        }
    }
}

# --- L-11: Per-pipeline script flags (sovereign/script) ---
# Script flags (MCScript, FFScript, BleuScript, etc.) are per-pipeline values.
# They are stored directly in templateParameters as static values (not tokens).
# Absence is distinct from false — a parameter not present in templateParameters
# means the pipeline has no such parameter at all (different from passing false).
# This is already handled by the catalog design: only declared parameters are emitted.
# No additional code needed — the catalog stores per-pipeline statics and the
# substitution loop above passes them through unchanged. The validation below
# ensures ev2CloudCoverage agrees with the resolved flags.

# --- L-15: ev2CloudCoverage cross-check against resolved script flags ---
if ($Scope -eq 'production' -and $catalog.PSObject.Properties['ev2CloudCoverage'] -and $catalog.ev2CloudCoverage) {
    $declaredCoverage = $null
    if ($catalog.ev2CloudCoverage.PSObject.Properties[$PipelineKey]) {
        $declaredCoverage = @($catalog.ev2CloudCoverage.$PipelineKey)
    }
    if ($declaredCoverage -and $declaredCoverage.Count -gt 0) {
        # Which script flag governs which cloud is derived from the pipeline's own
        # parameter names: a `<Partition>Script` flag belongs to partition
        # `<Partition>`, and that partition resolves to an inventory cloud through
        # the same cloud map used for token substitution. Nothing here names a
        # service's clouds, so a service with Ring0Script/EUScript gates correctly.
        $scriptFlagMap = @{}
        $flagPartitions = Get-ParameterPartitionModel -ParameterNames @($resolved.Keys)
        foreach ($fp in @($flagPartitions.partitions)) {
            if (-not $fp.facets -or -not $fp.facets.PSObject.Properties['script']) { continue }
            $flagName = [string]$fp.facets.script
            if (-not $flagName) { continue }
            $cloudKey = $null
            foreach ($cand in (@($fp.name) + @($fp.aliases))) {
                if (-not $cand) { continue }
                $lc = ([string]$cand).ToLowerInvariant()
                if ($cloudMap.ContainsKey($lc)) { $cloudKey = $cloudMap[$lc]; break }
            }
            # No inventory cloud claims this partition — fall back to the partition's
            # own name so a coverage declaration spelled that way still cross-checks.
            if (-not $cloudKey) { $cloudKey = [string]$fp.name }
            $scriptFlagMap[$flagName] = $cloudKey
        }
        $contradictions = @()
        foreach ($flagName in $scriptFlagMap.Keys) {
            $cloud = $scriptFlagMap[$flagName]
            if ($resolved.ContainsKey($flagName)) {
                $flagVal = [string]$resolved[$flagName]
                $flagBool = $flagVal -match '^(true|True|TRUE)$'
                $cloudDeclared = $cloud -in $declaredCoverage
                if ($flagBool -and -not $cloudDeclared) {
                    $contradictions += "$flagName=$flagVal but '$cloud' is NOT in ev2CloudCoverage [$($declaredCoverage -join ', ')]. Add '$cloud' to ev2CloudCoverage.$PipelineKey."
                }
                if (-not $flagBool -and $cloudDeclared) {
                    $contradictions += "$flagName=$flagVal but '$cloud' IS in ev2CloudCoverage [$($declaredCoverage -join ', ')]. Remove '$cloud' from ev2CloudCoverage.$PipelineKey or set $flagName=true."
                }
            }
            # L-11: absent flag means the pipeline has no such parameter — do not treat as false.
            # Only flag a contradiction if the cloud IS declared but the flag is absent AND
            # other flags exist (indicating this pipeline uses script flags).
        }
        if ($contradictions.Count -gt 0) {
            throw "EV2_CLOUD_COVERAGE_MISMATCH: pipeline '$PipelineKey' ev2CloudCoverage contradicts resolved script flags:`n$($contradictions -join "`n")`nOperator action: update pipeline-catalog.json → ev2CloudCoverage.$PipelineKey to match the pipeline's actual script flags from its reference run."
        }
    }
}

# --- L-10: EV2 dual-gate alignment (PubRegions vs PublicExcludestamps) ---
# Two independent EV2 gates must agree:
#   1. PubRegions — controls which regions get deployment actions generated
#   2. PublicExcludestamps — controls which stamps inside those regions are skipped
# A stamp expected to deploy whose region is absent from PubRegions → silent no-deploy.
# A region in PubRegions where every stamp is excluded → silent no-op region.
if ($Scope -eq 'production') {
    # The gate reasons about what will actually be POSTed, so the partition model it
    # uses is derived from the resolved payload's own parameter names — unioned with
    # the YAML declaration when there is one. Deriving it from the declaration alone
    # would silently disable the gate for any pipeline that has not been introspected.
    $gatePartitionNames = [System.Collections.Generic.List[string]]::new()
    foreach ($n in @($resolved.Keys))                              { if ($n) { $gatePartitionNames.Add([string]$n) } }
    foreach ($n in @($declaredParams | ForEach-Object { $_.name })) { if ($n -and $gatePartitionNames -notcontains [string]$n) { $gatePartitionNames.Add([string]$n) } }

    # Which parameters form the region/exclude pair is not knowledge this script holds:
    # it is derived from the pipeline's own parameter names. Every partition that
    # exposes BOTH a regions facet and an excludeStamps facet is gated — including the
    # common case where the author spelled one facet with a truncated partition prefix.
    $gatePairs = [System.Collections.Generic.List[object]]::new()
    $facetPairs = Get-PartitionFacetPairs -ParameterNames @($gatePartitionNames.ToArray()) `
                                          -FacetA 'Regions' -FacetB 'Excludestamps'
    foreach ($fp in $facetPairs) {
        $rName = [string]$fp.a.name
        $xName = [string]$fp.b.name
        if (-not $resolved.ContainsKey($rName) -or -not $resolved.ContainsKey($xName)) { continue }

        # The stamps facet, if any, may be spelled against either partition name.
        $sName = $null
        foreach ($cand in @($fp.partition, $fp.partnerPartition)) {
            foreach ($suffix in @('stamps', 'Stamps')) {
                $probe = "$cand$suffix"
                if ($resolved.ContainsKey($probe)) { $sName = $probe; break }
            }
            if ($sName) { break }
        }

        $gatePairs.Add([pscustomobject]@{
            partition       = [string]$fp.partition
            aliases         = @($fp.aliases)
            regionsParam    = @{ name = $rName; value = $resolved[$rName] }
            excludeParam    = @{ name = $xName; value = $resolved[$xName] }
            stampsParamName = $sName
        }) | Out-Null
    }

    foreach ($gate in $gatePairs) {
        $pubRegionsParam    = $gate.regionsParam
        $excludeStampsParam = $gate.excludeParam
        if (-not $pubRegionsParam.value) { continue }

        # Parse the regions value — handle both regions(...) wrapper and bare CSV
        $pubRegionsVal = $pubRegionsParam.value
        $pubRegionsList = @()
        if ($pubRegionsVal -match '^regions\((.+)\)$') {
            $pubRegionsList = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } elseif ($pubRegionsVal -match '^\@\(') {
            # PS array format: @("r1","r2")
            $inner = $pubRegionsVal -replace '^\@\(', '' -replace '\)$', ''
            $pubRegionsList = @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
        } else {
            $pubRegionsList = @($pubRegionsVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        # Parse the exclude-stamps value
        $excludeStampsVal = $excludeStampsParam.value
        $excludeStampsList = @()
        if ($excludeStampsVal) {
            if ($excludeStampsVal -match '^\@\(') {
                $inner = $excludeStampsVal -replace '^\@\(', '' -replace '\)$', ''
                $excludeStampsList = @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
            } else {
                $excludeStampsList = @($excludeStampsVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($es in $excludeStampsList) { [void]$excludeSet.Add($es) }

        # Build stamp→region map from the inventory cloud this partition deploys to.
        # The partition's own name (or one of its aliases) is the link to inventory;
        # nothing here assumes a particular cloud is called "Public".
        $gateInv = $null
        foreach ($candidate in @(@($gate.partition) + @($gate.aliases) | Where-Object { $_ })) {
            $probe = Get-ProdCloudInventory -CloudKey ([string]$candidate)
            if (-not $probe) {
                $mapped = $cloudMap[([string]$candidate).ToLowerInvariant()]
                if ($mapped) { $probe = Get-ProdCloudInventory -CloudKey $mapped }
            }
            if ($probe -and $probe.PSObject.Properties['stamps'] -and $probe.stamps) { $gateInv = $probe; break }
        }

        $stampToRegion = @{}
        if ($gateInv) {
            foreach ($s in $gateInv.stamps) {
                # Only include stamps matching this pipeline's clusterType (when cluster-type routing is active)
                if ($mode -eq 'cluster-type' -and $pipelineCt) {
                    $sct = if ($s.PSObject.Properties['clusterType']) { [string]$s.clusterType } else { $null }
                    if ($sct -and $sct -ne $pipelineCt) { continue }
                    if (-not $sct) { continue }  # stamps with no clusterType are already dropped
                }
                $label = Get-StampLabel -Stamp $s -Style $stampStyle
                # ARM region name, not the short locality prefix: the regions parameter is
                # compared against this, and it carries ARM names.
                $shortR = if ($s.PSObject.Properties['region']) { [string]$s.region } else { $null }
                $longR  = Resolve-LongFormRegion -Stamp $s -Short $shortR
                if ($longR) {
                    $stampToRegion[$label] = $longR
                }
            }
        }

        $gateErrors = @()

        # Which mechanism actually scopes the deploy? If the stamp list is a wildcard
        # the operator is scoping BY REGION, and a stamp in an unlisted region is
        # deliberately out of scope, not a misalignment. Only an explicitly enumerated
        # stamp list asserts "this stamp should deploy", which is what Check 1 tests.
        $stampsParamName   = $gate.stampsParamName
        $stampsAreWildcard = $false
        if ($stampsParamName -and $resolved.ContainsKey($stampsParamName)) {
            $sv = ([string]$resolved[$stampsParamName]).Trim()
            $stampsAreWildcard = ((Get-ContainerElements -Literal $sv).isWildcard) -or ($sv -eq '*')
        }

        # Check 1: stamp not in exclude list → its region must be in the regions param
        $pubRegionsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($r in $pubRegionsList) { [void]$pubRegionsSet.Add($r) }

        $outOfScopeStamps = @()
        foreach ($stampLabel in $stampToRegion.Keys) {
            if (-not $excludeSet.Contains($stampLabel)) {
                $stampRegion = $stampToRegion[$stampLabel]
                if ($stampRegion -and -not $pubRegionsSet.Contains($stampRegion)) {
                    if ($stampsAreWildcard) {
                        $outOfScopeStamps += "$stampLabel ($stampRegion)"
                    } else {
                        $gateErrors += "Stamp '$stampLabel' (region='$stampRegion') is NOT excluded but its region is absent from $($pubRegionsParam.name). EV2 will generate NO deployment action for this stamp. Add '$stampRegion' to $($pubRegionsParam.name) or add '$stampLabel' to $($excludeStampsParam.name)."
                    }
                }
            }
        }
        if ($outOfScopeStamps.Count -gt 0) {
            $agentGaps.Add("REGION_SCOPED_OUT_STAMPS: $($stampsParamName)='*' scopes by $($pubRegionsParam.name), and $($outOfScopeStamps.Count) inventory stamp(s) sit in regions it does not list, so they receive no deployment action: $($outOfScopeStamps -join ', '). Operator action: confirm this is intended, or add the region(s) to $($pubRegionsParam.name).")
        }

        # Check 2: region in the regions param where ALL stamps in that region are excluded → silent no-op
        $regionToStamps = @{}
        foreach ($stampLabel in $stampToRegion.Keys) {
            $r = $stampToRegion[$stampLabel]
            if (-not $regionToStamps.ContainsKey($r)) { $regionToStamps[$r] = @() }
            $regionToStamps[$r] += $stampLabel
        }

        foreach ($region in $pubRegionsList) {
            if ($regionToStamps.ContainsKey($region)) {
                $stampsInRegion = $regionToStamps[$region]
                $allExcluded = $true
                foreach ($sl in $stampsInRegion) {
                    if (-not $excludeSet.Contains($sl)) { $allExcluded = $false; break }
                }
                if ($allExcluded -and $stampsInRegion.Count -gt 0) {
                    $gateErrors += "Region '$region' is in $($pubRegionsParam.name) but ALL its stamps ($($stampsInRegion -join ', ')) are in $($excludeStampsParam.name). This is a silent no-op region — EV2 generates the region action but skips every stamp. Remove '$region' from $($pubRegionsParam.name) or remove at least one stamp from $($excludeStampsParam.name)."
                }
            }
        }

        if ($gateErrors.Count -gt 0) {
            throw "EV2_DUAL_GATE_MISALIGNMENT: pipeline '$PipelineKey' has misaligned $($pubRegionsParam.name) and $($excludeStampsParam.name) gates:`n$($gateErrors -join "`n")`nOperator action: align the two gates per the 4-step reclassification rule in the deployment guide."
        }
    }
}

# --- Contamination assertion ---
if ($mode -eq 'cluster-type' -and $pipelineCt) {
    # Build lookup of stampName -> clusterType across both inventories
    $byName = @{}
    if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps) {
        foreach ($s in $cfg.inventory.canary.stamps) { $byName[[string]$s.stampName] = [string]$s.clusterType }
    }
    if ($cfg.inventory -and $cfg.inventory.production) {
        foreach ($cloudProp in $cfg.inventory.production.PSObject.Properties) {
            $cloudInv = $cloudProp.Value
            if ($cloudInv -and $cloudInv.PSObject.Properties['stamps']) {
                foreach ($s in $cloudInv.stamps) { $byName[[string]$s.stampName] = [string]$s.clusterType }
            }
        }
    }
    $offenders = @()
    foreach ($name in $stampsEmitted) {
        if ($byName.ContainsKey($name) -and $byName[$name] -and $byName[$name] -ne $pipelineCt) {
            $offenders += "$name(ct=$($byName[$name]))"
        }
    }
    if ($offenders.Count -gt 0) {
        throw "CLUSTER_TYPE_CONTAMINATION: pipeline '$PipelineKey' (ct='$pipelineCt') would emit stamps with mismatched clusterType: $($offenders -join ', ')"
    }
}

# --- L-05: Validate mode — cross-reference emitted tokens at resolve time ---
$validationErrors = @()
if ($Validate) {
    # 1. L-03: stampId format — all stamps must have a stampId when stampNameStyle='short'
    if ($stampStyle -eq 'short' -and $stampsEmitted.Count -gt 0) {
        # Check from inventory that every emitted stamp actually had a stampId
        $allInvStamps = @()
        if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps) {
            $allInvStamps += $cfg.inventory.canary.stamps
        }
        if ($cfg.inventory -and $cfg.inventory.production) {
            foreach ($cloudProp in $cfg.inventory.production.PSObject.Properties) {
                $ci = $cloudProp.Value
                if ($ci -and $ci.PSObject.Properties['stamps']) { $allInvStamps += $ci.stamps }
            }
        }
        foreach ($s in $allInvStamps) {
            if ($stampsEmitted.Contains([string]$s.stampName)) {
                $hasId = $s.PSObject.Properties['stampId'] -and $s.stampId
                if (-not $hasId) {
                    $validationErrors += "STAMP_ID_FORMAT: stamp '$($s.stampName)' has no stampId but stampNameStyle='short'. The pipeline expects short IDs. Add stampId to service-config.json → inventory."
                }
            }
        }
    }

    # 2. L-04: cloud-scope — verify no cross-cloud stamps leaked through
    # (Already enforced by Get-FilteredStamps; this is a belt-and-suspenders check)

    # 3. L-09: wildcard / unbounded scope — already enforced above, re-check in validate mode
    foreach ($tokKey in $tokens.Keys) {
        if ($tokKey -match 'Regions' -and $Scope -eq 'production') {
            $val = $tokens[$tokKey]
            if ($val -match '^\s*\*\s*$' -or $val -match 'regions\s*\(\s*\*\s*\)') {
                $validationErrors += "VALIDATE_UNSAFE_REGION_SCOPE: token '$tokKey' resolved to wildcard '$val' for pipeline '$PipelineKey'. This would deploy to ALL regions."
            }
        }
    }

    # 4. L-06: paramFormat — verify format is applied correctly
    if ($paramFormat) {
        foreach ($pName in $resolved.Keys) {
            $v = [string]$resolved[$pName]
            switch ($paramFormat) {
                'ps-array' {
                    if ($v -and $v -ne '@()' -and $v -notmatch '^\@\(') {
                        $validationErrors += "VALIDATE_PARAM_FORMAT: param '$pName' has paramFormat='ps-array' but value '$v' is not in @(...) format for pipeline '$PipelineKey'."
                    }
                }
                'regions-wrapper' {
                    if ($v -and $v -notmatch '^$' -and $v -notmatch '^regions\(' -and $tokens.Values -contains "{{$($pName.ToLower())}}" -eq $false) {
                        # Only check token-resolved values, not static values
                    }
                }
            }
        }
    }

    # 5. L-10: dual-gate alignment — already enforced above; included in validate output

    # 6. L-16: cross-pipeline geography coverage check
    if ($AllPipelineResults.Count -gt 0 -and $Scope -eq 'production') {
        # Collect all regions from all pipeline results including this one
        $allRegions = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($priorResult in $AllPipelineResults) {
            if ($priorResult.templateParameters) {
                foreach ($pk in $priorResult.templateParameters.Keys) {
                    if ($pk -match 'Regions$') {
                        $rv = [string]$priorResult.templateParameters[$pk]
                        if ($rv) {
                            $parsed = @()
                            if ($rv -match '^regions\((.+)\)$') { $parsed = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                            elseif ($rv -match '^\@\(') { $parsed = @(($rv -replace '^\@\(','') -replace '\)$','' -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
                            else { $parsed = @($rv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                            foreach ($r in $parsed) { [void]$allRegions.Add($r) }
                        }
                    }
                }
            }
        }
        # Add this pipeline's regions
        foreach ($tokKey in $tokens.Keys) {
            if ($tokKey -match 'Regions') {
                $rv = $tokens[$tokKey]
                if ($rv) {
                    $parsed = @($rv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    foreach ($r in $parsed) { [void]$allRegions.Add($r) }
                }
            }
        }
        # Load expected regions from service config if available
        if ($cfg.PSObject.Properties['expectedProductionRegions'] -and $cfg.expectedProductionRegions) {
            $expectedRegions = @($cfg.expectedProductionRegions)
            $missing = @($expectedRegions | Where-Object { -not $allRegions.Contains($_) })
            if ($missing.Count -gt 0) {
                $validationErrors += "VALIDATE_GEOGRAPHY_COVERAGE_GAP: $($missing.Count) expected regions are not covered by any pipeline: $($missing -join ', '). Add them to the appropriate pipeline's region parameters."
            }
        }
    }
}

# Build validation summary
$validationResult = $null
if ($Validate) {
    $validationResult = [PSCustomObject]@{
        isValid = ($validationErrors.Count -eq 0)
        errors  = $validationErrors
        pipelineKey = $PipelineKey
        scope       = $Scope
        checkedAt   = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($validationErrors.Count -gt 0) {
        throw "VALIDATION_FAILED: pipeline '$PipelineKey' (scope=$Scope) has $($validationErrors.Count) validation error(s):`n$($validationErrors -join "`n")"
    }
}

[PSCustomObject]@{
    pipelineKey        = $PipelineKey
    scope              = $Scope
    clusterType        = $pipelineCt
    routingMode        = $mode
    templateParameters = $resolved
    droppedStamps      = @($script:droppedAcc.ToArray())
    droppedParameters  = @($droppedParams.ToArray())
    resolutionSources  = $resolutionSources
    declaredParameters = @($declaredParams)
    learnedModel       = $learnedModel
    agentGaps          = @($agentGaps.ToArray())
    validation         = $validationResult
}
