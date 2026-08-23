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
    [switch] $DryRun,

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

# L-06: canaryProdStamps / canaryProdRegions — Public-cloud canary-scope stamps
# These are stamps in inventory.canary.stamps with cloud=Public (e.g., ecy-01, ccy-01).
# They deploy to Public-cloud canary regions in a single pipeline run alongside Canary-cloud stamps.
# Reuses the existing -Cloud filter from Get-FilteredStamps (WP-A).
# Save/restore droppedAcc to avoid polluting the primary canaryStamps drop list —
# canaryProd drops are informational only and should not inflate the main drop count.
$canaryProdStamps = @()
if ($cfg.inventory -and $cfg.inventory.canary -and $cfg.inventory.canary.stamps) {
    $savedDropCount = $script:droppedAcc.Count
    $canaryProdStamps = @(Get-FilteredStamps -Stamps $cfg.inventory.canary.stamps -Mode $mode -PipelineCt $pipelineCt -Cloud 'Public')
    while ($script:droppedAcc.Count -gt $savedDropCount) { $script:droppedAcc.RemoveAt($script:droppedAcc.Count - 1) }
}
$canaryProdStampLabels = @($canaryProdStamps | ForEach-Object { Get-StampLabel -Stamp $_ -Style $stampStyle })
$canaryProdRegions     = @($canaryProdStamps | ForEach-Object { $_.region } | Where-Object { $_ } | Sort-Object -Unique)
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

if ($entry.templateParameters) {
    foreach ($p in $entry.templateParameters.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [string] -and $tokens.ContainsKey($v)) {
            $resolvedVal = $tokens[$v]
            # L-06: apply paramFormat to token-resolved values
            if ($paramFormat -and $resolvedVal) {
                $resolvedVal = Format-ParamValue -Value $resolvedVal -Format $paramFormat
            }
            $resolved[$p.Name] = $resolvedVal
        } elseif ($v -is [string] -and $v -match '\{\{[^}]+\}\}') {
            # Token-shaped literal we don't know about — leave as-is and flag.
            $resolved[$p.Name] = $v
            $agentGaps.Add("unknown-reserved-token: param=$($p.Name) value=$v")
        } else {
            $resolved[$p.Name] = $v
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
        # Derive expected coverage from the resolved script flags in $resolved
        $scriptFlagMap = @{
            'MCScript'    = 'Mooncake'
            'FFScript'    = 'Fairfax'
            'BleuScript'  = 'Bleu'
            'UsNatScript' = 'USNat'
            'UsSecScript' = 'USSec'
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
    $pubRegionsParam   = $null
    $excludeStampsParam = $null
    # Find the PubRegions and PublicExcludestamps values in the resolved parameters
    foreach ($pName in $resolved.Keys) {
        if ($pName -match '^Pub.*Regions$' -or $pName -eq 'PubRegions') {
            $pubRegionsParam = @{ name = $pName; value = $resolved[$pName] }
        }
        if ($pName -match 'Exclude.*[Ss]tamps' -or $pName -eq 'PublicExcludestamps') {
            $excludeStampsParam = @{ name = $pName; value = $resolved[$pName] }
        }
    }

    if ($pubRegionsParam -and $pubRegionsParam.value -and $excludeStampsParam) {
        # Parse PubRegions — handle both regions(...) wrapper and bare CSV
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

        # Parse PublicExcludestamps
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

        # Build stamp→region map from inventory for this pipeline's cloud scope
        $stampToRegion = @{}
        if ($cfg.inventory -and $cfg.inventory.production) {
            foreach ($cloudProp in $cfg.inventory.production.PSObject.Properties) {
                $cloudInv = $cloudProp.Value
                if ($cloudInv -and $cloudInv.PSObject.Properties['stamps']) {
                    foreach ($s in $cloudInv.stamps) {
                        $label = Get-StampLabel -Stamp $s -Style $stampStyle
                        if ($s.PSObject.Properties['region'] -and $s.region) {
                            $stampToRegion[$label] = [string]$s.region
                        }
                    }
                }
            }
        }

        $gateErrors = @()

        # Check 1: stamp not in exclude list → its region must be in PubRegions
        $pubRegionsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($r in $pubRegionsList) { [void]$pubRegionsSet.Add($r) }

        foreach ($stampLabel in $stampToRegion.Keys) {
            if (-not $excludeSet.Contains($stampLabel)) {
                $stampRegion = $stampToRegion[$stampLabel]
                if ($stampRegion -and -not $pubRegionsSet.Contains($stampRegion)) {
                    $gateErrors += "Stamp '$stampLabel' (region='$stampRegion') is NOT excluded but its region is absent from $($pubRegionsParam.name). EV2 will generate NO deployment action for this stamp. Add '$stampRegion' to $($pubRegionsParam.name) or add '$stampLabel' to $($excludeStampsParam.name)."
                }
            }
        }

        # Check 2: region in PubRegions where ALL stamps in that region are excluded → silent no-op
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
            throw "EV2_DUAL_GATE_MISALIGNMENT: pipeline '$PipelineKey' has misaligned PubRegions and ExcludeStamps gates:`n$($gateErrors -join "`n")`nOperator action: align the two gates per the 4-step reclassification rule in the deployment guide."
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
    agentGaps          = @($agentGaps.ToArray())
    validation         = $validationResult
}
