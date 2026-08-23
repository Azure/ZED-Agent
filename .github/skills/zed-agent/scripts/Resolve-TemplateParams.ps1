<#
.SYNOPSIS
    Resolve reserved {{...}} tokens in a pipeline's templateParameters using
    service-config.json inventory + pipeline-catalog.json routing. Enforces
    cluster-type isolation when routing.mode='cluster-type'.

.DESCRIPTION
    Single source of truth for template-parameter substitution used by dry-run
    (Invoke-PipelineDryRun.ps1) and Step 15 real-release. Behavior:

      - Reads pipeline-catalog.json -> <scope>.<key>.templateParameters.
      - Loads canary inventory from service-config.json -> inventory.canary.stamps.
      - Loads production inventory from service-config.json -> inventory.production.<cloud>.
      - Filters stamps by entry.clusterType when {scope}Routing.mode == 'cluster-type'.
      - Substitutes the reserved token set into a hashtable of resolved params.
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
      pipelineKey, scope, clusterType,
      templateParameters (hashtable, all tokens substituted),
      droppedStamps (stamps removed by cluster-type filter),
      agentGaps (array of warning strings)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PipelineKey,
    [Parameter(Mandatory)] [ValidateSet('canary','production')] [string] $Scope,
    [Parameter(Mandatory)] [string] $CurrentBranch,
    [Parameter(Mandatory)] [string] $ServiceConfigPath,
    [Parameter(Mandatory)] [string] $PipelineCatalogPath,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

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
$script:droppedAcc = New-Object System.Collections.Generic.List[object]
$agentGaps         = New-Object System.Collections.Generic.List[string]

function Get-FilteredStamps {
    param($Stamps, [string]$Mode, [string]$PipelineCt, [string]$Cloud)
    if (-not $Stamps) { return @() }
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Stamps) {
        # Cloud filter (L-04): when $Cloud is supplied, keep only stamps whose cloud matches or that have no cloud property
        if ($Cloud) {
            $sCloud = if ($s.PSObject.Properties['cloud']) { [string]$s.cloud } else { $null }
            if ($sCloud -and $sCloud -ne $Cloud) {
                $script:droppedAcc.Add(@{ stampName = $s.stampName; cloud = $sCloud; reason = "cloud '$sCloud' != required '$Cloud'" })
                continue
            }
        }
        # Cluster-type filter (original logic)
        if ($Mode -ne 'cluster-type') { $kept.Add($s); continue }
        $sct = if ($s.PSObject.Properties['clusterType']) { [string]$s.clusterType } else { $null }
        if (-not $sct) {
            throw "INVENTORY_MISSING_CLUSTERTYPE: stamp '$($s.stampName)' has no clusterType but $routingProp.mode='cluster-type'. Run inventory refresh."
        }
        if ($sct -eq $PipelineCt) { $kept.Add($s) }
        else { $script:droppedAcc.Add(@{ stampName = $s.stampName; clusterType = $sct; reason = "ct '$sct' != pipeline '$PipelineCt'" }) }
    }
    return @($kept.ToArray())
}

# Canary stamps (L-04: pass Cloud='Canary' so cross-cloud stamps are filtered)
$canaryStamps = @()
if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps) {
    $canaryStamps = @(Get-FilteredStamps -Stamps $cfg.inventory.canary.stamps -Mode $mode -PipelineCt $pipelineCt -Cloud 'Canary')
}

# Cloud -> service-config inventory.production key
$cloudMap = @{
    'pub'   = 'Public'
    'ff'    = 'Fairfax'
    'mc'    = 'Mooncake'
    'usnat' = 'USNat'
    'ussec' = 'USSec'
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

# --- Build token table ---
$stampsEmitted = New-Object System.Collections.Generic.HashSet[string]

function Add-Emitted {
    param($Stamps)
    foreach ($s in $Stamps) { [void]$stampsEmitted.Add([string]$s.stampName) }
}

$tokens = @{}
$tokens['{{currentBranch}}'] = $CurrentBranch
# U-06: sdpType from catalog entry, defaulting to 'Express' for backward compatibility
$sdpTypeDefault = 'Express'
if ($entry.PSObject.Properties['sdpType'] -and $entry.sdpType) {
    $sdpTypeDefault = [string]$entry.sdpType
}
$tokens['{{sdpType}}']       = if ($DryRun) { 'Test' } else { $sdpTypeDefault }
$tokens['{{validateOnly}}']  = if ($DryRun) { 'true' } else { 'false' }
# L-09: populate excludeStamps from CCOA exclusions
$tokens['{{excludeStamps}}'] = ($ccoaExcludedStamps -join $joinSep)

# Canary tokens
if ($Scope -eq 'canary' -or $canaryStamps.Count -gt 0) {
    # L-03: use Get-StampLabel (respects stampNameStyle: short→stampId, full→stampName)
    $canaryStampLabels = @($canaryStamps | ForEach-Object { Get-StampLabel -Stamp $_ -Style $stampStyle })
    $canaryRegions     = @($canaryStamps | ForEach-Object { $_.region } | Where-Object { $_ } | Sort-Object -Unique)
    $tokens['{{canaryStamps}}']  = ($canaryStampLabels -join $joinSep)
    $tokens['{{canaryRegions}}'] = ($canaryRegions -join $joinSep)
    if ($Scope -eq 'canary') { Add-Emitted -Stamps $canaryStamps }
} else {
    $tokens['{{canaryStamps}}']  = ''
    $tokens['{{canaryRegions}}'] = ''
}

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
        $regions = @($prodStamps | ForEach-Object { $_.region } | Where-Object { $_ } | Sort-Object -Unique)
    }
    # L-09: subtract CCOA-excluded regions
    if ($ccoaExcludedRegions.Count -gt 0 -and $regions.Count -gt 0) {
        $excludeRegSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($er in $ccoaExcludedRegions) { [void]$excludeRegSet.Add($er) }
        $regions = @($regions | Where-Object { -not $excludeRegSet.Contains($_) })
    }
    $tokens[$stampsTok]  = ($stampLabels -join $joinSep)
    $tokens[$regionsTok] = ($regions    -join $joinSep)

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

# --- Substitute into templateParameters ---
$resolved = @{}
if ($entry.templateParameters) {
    foreach ($p in $entry.templateParameters.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [string] -and $tokens.ContainsKey($v)) {
            $resolved[$p.Name] = $tokens[$v]
        } elseif ($v -is [string] -and $v -match '\{\{[^}]+\}\}') {
            # Token-shaped literal we don't know about — leave as-is and flag.
            $resolved[$p.Name] = $v
            $agentGaps.Add("unknown-reserved-token: param=$($p.Name) value=$v")
        } else {
            $resolved[$p.Name] = $v
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

[PSCustomObject]@{
    pipelineKey        = $PipelineKey
    scope              = $Scope
    clusterType        = $pipelineCt
    routingMode        = $mode
    templateParameters = $resolved
    droppedStamps      = @($script:droppedAcc.ToArray())
    agentGaps          = @($agentGaps.ToArray())
}
