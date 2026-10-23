<#
.SYNOPSIS
    Resolves the authoritative stamp inventory for a service, scoped to
    canary or production, by joining a stamp source with AzureServiceConfig.

.DESCRIPTION
    Layer 1 of the canary-stamp-resolution work (capability B). Produces a
    single inventory object that downstream steps (canary deploy, rollback,
    BVT routing, production fan-out) can consume without ever hand-coding
    a region or layout string.

    Stamp sources by scope:
      canary      → service-config.json → inventory.canary.stamps
                    (owner-curated; canary set is tiny and stable).
      production  → service-config.json → kusto.production query
                    (live; production fleet changes too often to curate).

    Region/cloud enrichment is ALWAYS from AzureServiceConfig.json via
    Get-AzureServiceConfig.ps1 (live → cache → snapshot).

    Stamp-name grammar (per service-config.schema.json → inventory.canary):
        {shortName}-{layout}-{stampTag}{index}
        ex: ea-can02-prot1, eus-pod01-prot2, eus2-pod01-rec1d

    Stamp-name normalization (service-config.json → inventory.stampNaming):
      partitionSuffixPattern  opt-in regex for a per-partition Kusto suffix
                              (e.g. '-p[0-9]+[a-z]*' folds
                              'ecy-pod01-coord1-p1a' into 'ecy-pod01-coord1').
      sdsStampIdPattern       regex (named groups shortName, index) for SDS
                              short StampIds; default '^(?<shortName>[a-z0-9]+)-(?<index>[0-9]+)$'.
      SDS reconciliation pairs stamps on the cloud-local key
      {shortName}-{index} (numeric index unpadded), so SDS 'acl-01' and
      Kusto 'acl-pod01-coord1' are the same stamp. Only Kusto stamps in the
      reconciled cloud are compared; others go to kustoOutOfScope.

    Cluster-type extraction (production scope only) reuses the same
    extraction modes as Resolve-PipelinesByClusterType.ps1
    (deployment-unit-substring | column | custom), driven by
    kusto.production.clusterTypeExtraction.

.PARAMETER Scope
    'canary' or 'production'.

.PARAMETER Cloud
    Optional filter on cloud Name (matches ASC Clouds[].Name).
    - canary scope     : ignored (canary inventory pins its own cloud).
    - production scope : if supplied, drops stamps whose resolved cloud
                         is not this one. If omitted, all clouds returned.

.PARAMETER NoCache
    Forces a fresh Kusto query (production) and a fresh ASC fetch (both).
    Does NOT invalidate the on-disk owner-curated canary inventory.

.PARAMETER PreferCache
    Opt-in for cache-first ASC resolution (acceptable when callers re-run
    inside the same release window and <=MaxAgeHours staleness is fine).
    Default behavior is LIVE-FIRST — ADO is the source of truth and the
    on-disk cache + committed snapshot only serve as fallbacks for outages.

.PARAMETER PipelineKey
    Names which entry under service-config.json → sds.<key> to use for SDS
    reconciliation. When omitted and exactly one key is configured, that one
    is auto-selected. Required when -Cloud is sovereign (Fairfax/Mooncake/
    USNat/USSec) because Kusto is unavailable and SDS is the sole source.

.PARAMETER SdsReconcile
    Force-enables the SDS cross-check pass even when only one source
    (Kusto) would otherwise be consulted. The pass runs automatically when
    a matching sds.<PipelineKey> block exists in service-config.json.

.PARAMETER MaxAgeHours
    Cache TTL applied to ASC and to production inventory cache. Default 24h.

.OUTPUTS
    PSCustomObject:
      scope          = 'canary' | 'production'
      cloud          = <name>  | $null (production unfiltered)
      stampTag       = <service.stampTag>
      stamps         = @(@{
                         stampName, shortName, layout, stampTag, index,
                         clusterType, cloud, ev2RegionName, ev2Geography,
                         dcRole, source
                      })
      regions        = @(@{ shortName, ev2RegionName, ev2Geography, layout, cloud })
      drift          = @(@{ stampName, reason, ... })
      sources        = @{ stamps = 'config'|'kusto'; ascSource = 'live'|'cache'|'snapshot'; ascPath; fetchedAt }
      kusto          = @{ ranAt; durationMs; rowCount } | $null
      stampNaming    = @{ partitionSuffixPattern; sdsStampIdPattern; foldedPartitions = @(@{ from; to }) }
      sdsReconciliation (production + sds configured) =
                       @{ hash; source; stampCount; cloud; matchedBy; matchedCount;
                          sdsOnly; kustoOnly; kustoOutOfScope; driftCount;
                          toleranceCount; withinTolerance }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('canary','production')][string]$Scope,
    [string]$Cloud,
    [string]$ServiceConfigPath,
    [string]$AscCachePath,
    [string]$AscSnapshotPath,
    [string]$QueriesDir,
    [string]$InventoryCachePath,
    [string]$PipelineKey,
    [int]   $MaxAgeHours = 24,
    [switch]$NoCache,
    [switch]$PreferCache,
    [switch]$SdsReconcile
)

$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\')).Path
if (-not $ServiceConfigPath)  { $ServiceConfigPath  = Join-Path $repoRoot '.github\skills\zed-agent\service-config.json' }
if (-not $QueriesDir)         { $QueriesDir         = Join-Path $repoRoot '.github\skills\zed-agent\queries' }
if (-not $InventoryCachePath) { $InventoryCachePath = Join-Path $repoRoot ".zed-agent\cache\inventory.$Scope.json" }
$ascScript = Join-Path $PSScriptRoot 'Get-AzureServiceConfig.ps1'

if (-not (Test-Path $ServiceConfigPath)) { throw "service-config.json not found at $ServiceConfigPath. Run 'setup-service' first." }
if (-not (Test-Path $ascScript))         { throw "Get-AzureServiceConfig.ps1 sibling script missing at $ascScript." }

$config = Get-Content $ServiceConfigPath -Raw | ConvertFrom-Json
$stampTag = $config.service.stampTag
if (-not $stampTag) { throw "service-config.json → service.stampTag is required (e.g. 'prot', 'rec'). Run 'setup-service group 1'." }

# ── SDS configuration resolution ──────────────────────────────────────────
# Sovereign clouds cannot be reached from setup-service's PME tenant Kusto.
# Get-StampInventoryFromSds.ps1 is the sole source for those clouds.
# This is Azure platform vocabulary, not service vocabulary, so it ships as a
# default — but a service whose cloud set differs can override it via
# service-config.json → inventory.sovereignClouds.
$sovereignClouds = if ($config.inventory -and $config.inventory.PSObject.Properties['sovereignClouds'] -and $config.inventory.sovereignClouds) {
    @($config.inventory.sovereignClouds)
} else {
    @('Fairfax','Mooncake','USNat','USSec','Bleu','BVTD3','EXP')
}
$isSovereignCloud = ($Cloud -and ($sovereignClouds -contains $Cloud))

# Default commercial (non-sovereign) cloud name, used when no -Cloud was supplied
# and SDS still needs a cloud to reconcile against. Azure platform vocabulary;
# overridable via service-config.json -> inventory.defaultCommercialCloud.
$defaultCommercialCloud = if ($config.inventory -and $config.inventory.PSObject.Properties['defaultCommercialCloud'] -and $config.inventory.defaultCommercialCloud) {
    [string]$config.inventory.defaultCommercialCloud
} else {
    'Public'
}

# Fallback cluster-type substring table, used only when a pipeline-catalog entry
# declares mode='deployment-unit-substring' WITHOUT its own .substrings array.
# Overridable service-wide via service-config.json → inventory.clusterTypeSubstrings.
# ORDERED: longer matches must precede the shorter ones they contain.
$defaultClusterTypeSubstrings = if ($config.inventory -and $config.inventory.PSObject.Properties['clusterTypeSubstrings'] -and $config.inventory.clusterTypeSubstrings) {
    @($config.inventory.clusterTypeSubstrings)
} else {
    @(
        [PSCustomObject]@{ match = '-sfmc'; clusterType = 'sfmc' }
        [PSCustomObject]@{ match = '-sfrp'; clusterType = 'sfrp' }
        [PSCustomObject]@{ match = '-sf';   clusterType = 'sfrp' }
        [PSCustomObject]@{ match = '-eap';  clusterType = 'eap'  }
        [PSCustomObject]@{ match = '-aks';  clusterType = 'aks'  }
    )
}

$sdsEntry = $null
if ($Scope -eq 'production' -and $config.sds) {
    $sdsBlock = $config.sds
    $sdsKeys = @($sdsBlock.PSObject.Properties.Name)
    if ($PipelineKey) {
        if ($sdsBlock.PSObject.Properties[$PipelineKey]) {
            $sdsEntry = $sdsBlock.$PipelineKey
        } else {
            throw "service-config.json → sds.$PipelineKey not found. Available keys: $($sdsKeys -join ', '). Run 'setup-service group 11.3b'."
        }
    } elseif ($sdsKeys.Count -eq 1) {
        $PipelineKey = $sdsKeys[0]
        $sdsEntry    = $sdsBlock.$PipelineKey
    } elseif ($sdsKeys.Count -gt 1) {
        if ($isSovereignCloud -or $SdsReconcile) {
            throw "-PipelineKey is required when service-config.json → sds has multiple keys: $($sdsKeys -join ', ')."
        }
    }
}
if ($isSovereignCloud -and -not $sdsEntry) {
    throw "Cloud '$Cloud' is sovereign and requires service-config.json → sds.<PipelineKey> to be populated. Run 'setup-service group 11.3b'."
}
$sdsReconcileEnabled = [bool]$sdsEntry -and ($Scope -eq 'production') -and ($SdsReconcile -or $sdsEntry)

# ── Stamp regex ────────────────────────────────────────────────────────
# {shortName}-{layout}-{stampTag}{index}.  All lowercase; index may be alnum.
$stampRegex = "^(?<shortName>[a-z0-9]+)-(?<layout>[a-z0-9]+)-(?<serviceTag>[a-z]+)(?<index>[a-z0-9]*)$"

# ── Stamp-name normalization (service-config.json → inventory.stampNaming) ──
# Kusto and SDS name the same stamp differently:
#   Kusto StampName : {shortName}-{layout}-{stampTag}{index}       e.g. acl-pod01-coord1
#                     + optional per-partition suffix              e.g. ecy-pod01-coord1-p1a
#   SDS StampId     : {shortName}-{index}  (Phobos 2022 StampId)   e.g. acl-01
# Both reduce to the same reconcile key {shortName}-{numeric index} within ONE
# cloud (acl-pod01-coord1 → acl-1, acl-01 → acl-1). Partition folding is
# OPT-IN (partitionSuffixPattern) because the suffix vocabulary is
# service-family specific; the SDS short-id pattern ships as a default because
# StampId is Phobos 2022 vocabulary. Both are overridable.
$stampNaming = if ($config.inventory -and $config.inventory.PSObject.Properties['stampNaming'] -and $config.inventory.stampNaming) { $config.inventory.stampNaming } else { $null }
# Without inventory.stampNaming the inventory behaves exactly as before (exact-name SDS
# reconciliation across clouds, SDS stamp names used as-is) — the normalization is opt-in.
$useStampNaming = [bool]$stampNaming
$partitionSuffixPattern = if ($stampNaming -and $stampNaming.PSObject.Properties['partitionSuffixPattern'] -and $stampNaming.partitionSuffixPattern) {
    [string]$stampNaming.partitionSuffixPattern
} else { $null }
$sdsStampIdPattern = if ($stampNaming -and $stampNaming.PSObject.Properties['sdsStampIdPattern'] -and $stampNaming.sdsStampIdPattern) {
    [string]$stampNaming.sdsStampIdPattern
} else {
    '^(?<shortName>[a-z0-9]+)-(?<index>[0-9]+)$'
}
foreach ($g in @('shortName','index')) {
    if (([regex]$sdsStampIdPattern).GetGroupNames() -notcontains $g) {
        throw "service-config.json → inventory.stampNaming.sdsStampIdPattern must declare a named group '(?<$g>...)'. Got: $sdsStampIdPattern"
    }
}
$foldedPartitions = [System.Collections.Generic.List[object]]::new()

function ConvertTo-BaseStampName {
    # Strips a configured per-partition suffix (e.g. '-p1a') from a Kusto
    # StampName. Only strips when what remains is itself a valid stamp name,
    # so a stampTag that happens to look like a suffix is never truncated.
    param([string]$Name)
    $n = "$Name".ToLowerInvariant()
    if ($partitionSuffixPattern) {
        $m = [regex]::Match($n, "(?:$partitionSuffixPattern)$")
        if ($m.Success -and $m.Index -gt 0) {
            $base = $n.Substring(0, $m.Index)
            if ($base -match $stampRegex) {
                return [PSCustomObject]@{ name = $base; partition = $m.Value }
            }
        }
    }
    return [PSCustomObject]@{ name = $n; partition = $null }
}

function Get-StampReconcileKey {
    # Cloud-local identity of a stamp, independent of naming style:
    # full name or SDS short id → '{shortName}-{index}', numeric index unpadded.
    param([string]$Name)
    $n = "$Name".ToLowerInvariant()
    $sn = $null; $idx = $null
    $full = [regex]::Match($n, $stampRegex)
    if ($full.Success) {
        $sn = $full.Groups['shortName'].Value; $idx = $full.Groups['index'].Value
    } else {
        $short = [regex]::Match($n, $sdsStampIdPattern)
        if ($short.Success) { $sn = $short.Groups['shortName'].Value.ToLowerInvariant(); $idx = $short.Groups['index'].Value.ToLowerInvariant() }
    }
    if (-not $sn) { return $n }
    if ($idx -match '^[0-9]+$') { $idx = [string][int64]$idx }
    return "$sn-$idx"
}

function ConvertFrom-SdsStampId {
    # SDS short id → canonical {shortName}-{layout}-{stampTag}{index} for a
    # known cloud layout. Returns the input unchanged if it is not a short id.
    param([string]$Name, [string]$Layout)
    $n = "$Name".ToLowerInvariant()
    if (-not $Layout -or $n -match $stampRegex) { return $n }
    $m = [regex]::Match($n, $sdsStampIdPattern)
    if (-not $m.Success) { return $n }
    $idx = $m.Groups['index'].Value.ToLowerInvariant()
    if ($idx -match '^[0-9]+$') { $idx = [string][int64]$idx }
    return "$($m.Groups['shortName'].Value.ToLowerInvariant())-$($Layout.ToLowerInvariant())-$stampTag$idx"
}

# ── Pull ASC (live → cache → snapshot) ────────────────────────────────
$ascArgs = @{ MaxAgeHours = $MaxAgeHours }
if ($NoCache)         { $ascArgs.NoCache       = $true }
if ($PreferCache)     { $ascArgs.PreferCache   = $true }
if ($AscCachePath)    { $ascArgs.CachePath     = $AscCachePath }
if ($AscSnapshotPath) { $ascArgs.SnapshotPath  = $AscSnapshotPath }
$asc = & $ascScript @ascArgs
if (-not $asc -or -not $asc.data.Clouds) { throw "ASC load returned no Clouds. Investigate Get-AzureServiceConfig.ps1 output." }
$ascData = $asc.data

# Build cloud lookup tables
# layoutIndex: layout → @(cloudEntry, ...)   (most layouts unique to one cloud, but allow many)
# regionIndex: "$cloudName::$shortName" → DC entry
$layoutIndex = @{}
$regionIndex = @{}
$allRegions  = [System.Collections.Generic.List[object]]::new()
foreach ($cl in $ascData.Clouds) {
    $layout = "$($cl.Layout)".ToLowerInvariant()
    if (-not $layoutIndex.ContainsKey($layout)) { $layoutIndex[$layout] = @() }
    $layoutIndex[$layout] += $cl
    foreach ($dc in @($cl.DataCenters)) {
        $sn = "$($dc.ShortName)".ToLowerInvariant()
        $regionIndex["$($cl.Name)::$sn"] = $dc
        $allRegions.Add([PSCustomObject]@{
            shortName     = $sn
            ev2RegionName = $dc.Ev2RegionName
            ev2Geography  = $dc.Ev2Geography
            layout        = $layout
            cloud         = $cl.Name
            dcRole        = @($dc.DatacenterType) -join ','
        })
    }
}

function Resolve-StampParts {
    param([string]$Name)
    $n = "$Name".ToLowerInvariant()
    if ($n -notmatch $stampRegex) { return $null }
    [PSCustomObject]@{
        stampName  = $n
        shortName  = $Matches.shortName
        layout     = $Matches.layout
        serviceTag = $Matches.serviceTag
        index      = $Matches.index
    }
}

function Resolve-RowClusterType {
    <#
    .SYNOPSIS
        Derive a stamp's clusterType from one Kusto row, driven entirely by
        kusto.<set>.clusterTypeExtraction so no service's vocabulary is baked in.

    .DESCRIPTION
        Modes:
          deployment-unit-substring — scan the row's DeploymentUnit value(s) and
              return the clusterType of the FIRST matching entry in
              $Extraction.substrings, an ORDERED array of { match, clusterType }.
              Order matters: put longer/more specific matches first, because a
              shorter match would otherwise swallow them.
              When .substrings is absent the caller's -DefaultSubstrings are used.
          column — read the clusterType verbatim from $Extraction.column.
          custom — not implemented; throws with the owner's notes.

    .PARAMETER Strict
        Throw on an unknown mode instead of returning $null. The production path
        wants the throw; the supplementary-cloud path tolerates it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$Extraction,
        [array]$DefaultSubstrings,
        [switch]$Strict
    )

    switch ($Extraction.mode) {
        'deployment-unit-substring' {
            $rules = if ($Extraction.PSObject.Properties['substrings'] -and $Extraction.substrings) {
                @($Extraction.substrings)
            } else {
                @($DefaultSubstrings)
            }
            if (-not $rules -or @($rules).Count -eq 0) {
                throw "clusterTypeExtraction.mode='deployment-unit-substring' has no .substrings and no default was supplied. Add an ordered substrings array of { match, clusterType } to the pipeline catalog."
            }

            # DeploymentUnit may arrive as a single value or as a set/array column.
            $units = @()
            if ($Row.PSObject.Properties['DeploymentUnit'])     { $units += @($Row.DeploymentUnit) }
            if ($Row.PSObject.Properties['set_DeploymentUnit']) { $units += @($Row.set_DeploymentUnit) }

            foreach ($u in $units) {
                $s = "$u".ToLowerInvariant()
                foreach ($rule in $rules) {
                    $m = "$($rule.match)".ToLowerInvariant()
                    if (-not $m) { continue }
                    if ($s -match [regex]::Escape($m)) { return "$($rule.clusterType)".ToLowerInvariant() }
                }
            }
            return $null
        }
        'column' {
            if (-not $Extraction.column) {
                if ($Strict) { throw "clusterTypeExtraction.mode='column' requires .column." }
                return $null
            }
            $v = $Row.($Extraction.column)
            if ($null -ne $v -and "$v".Length -gt 0) { return "$v".ToLowerInvariant() }
            return $null
        }
        'custom' {
            throw "clusterTypeExtraction.mode='custom' not implemented. Owner notes: $($Extraction.notes)"
        }
        default {
            if ($Strict) { throw "Unknown clusterTypeExtraction.mode '$($Extraction.mode)'." }
            return $null
        }
    }
}

function Resolve-CloudForStamp {
    param($Parts)
    # 1) Layout uniquely identifies a candidate cloud in nearly all cases.
    $candidates = @()
    if ($layoutIndex.ContainsKey($Parts.layout)) { $candidates = @($layoutIndex[$Parts.layout]) }
    # 2) Among layout-matching clouds, the one that ALSO has this shortName wins.
    foreach ($cl in $candidates) {
        if ($regionIndex.ContainsKey("$($cl.Name)::$($Parts.shortName)")) { return $cl }
    }
    # 3) Layout matches but region doesn't → return first candidate so caller can drift on region.
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

# ── Collect raw stamps (with optional clusterType) ────────────────────
$rawStamps = [System.Collections.Generic.List[object]]::new()
$kustoMeta = $null

if ($Scope -eq 'canary') {
    $canaryInv = $config.inventory.canary
    if (-not $canaryInv -or -not $canaryInv.stamps) {
        throw "service-config.json → inventory.canary.stamps is empty. Run 'setup-service group 4c' to enumerate canary stamps."
    }
    # Multi-cloud canary: each stamp carries its own cloud/region/layout.
    # Deprecated singular fields (canaryInv.cloud / canaryInv.layout) are used
    # only as a fallback so older configs still load without re-running setup.
    $fallbackCloud  = if ($canaryInv.cloud)  { "$($canaryInv.cloud)" }  else { $null }
    $fallbackLayout = if ($canaryInv.layout) { "$($canaryInv.layout)".ToLowerInvariant() } else { $null }
    foreach ($s in $canaryInv.stamps) {
        $perCloud  = if ($s.PSObject.Properties['cloud']  -and $s.cloud)  { "$($s.cloud)" }  else { $fallbackCloud }
        $perLayout = if ($s.PSObject.Properties['layout'] -and $s.layout) { "$($s.layout)".ToLowerInvariant() } else { $fallbackLayout }
        $ct        = if ($s.PSObject.Properties['clusterType'] -and $s.clusterType) { "$($s.clusterType)".ToLowerInvariant() } else { $null }
        $rawStamps.Add([PSCustomObject]@{
            stampName   = "$($s.stampName)".ToLowerInvariant()
            clusterType = $ct
            cloudHint   = $perCloud
            layoutHint  = $perLayout
            source      = 'config'
        })
    }
}
elseif ($isSovereignCloud) {
    # Sovereign cloud: SDS is the sole source. Build raw stamps directly from
    # the parsed SDS, scoped to this cloud. Kusto is not consulted.
    $sdsScript = Join-Path $PSScriptRoot 'Get-StampInventoryFromSds.ps1'
    if (-not (Test-Path $sdsScript)) { throw "Get-StampInventoryFromSds.ps1 sibling script missing at $sdsScript." }
    $sdsPath = if ($sdsEntry.localClonePath -and (Test-Path (Join-Path $sdsEntry.localClonePath $sdsEntry.path))) {
        Join-Path $sdsEntry.localClonePath $sdsEntry.path
    } else {
        Join-Path $repoRoot $sdsEntry.path
    }
    if (-not (Test-Path $sdsPath)) { throw "SDS file not found at '$sdsPath'. Set sds.$PipelineKey.localClonePath or ensure the repo clone is at '$repoRoot'." }
    $sdsInv = & $sdsScript -SdsPath $sdsPath -Cloud $Cloud -ServiceConfigPath $ServiceConfigPath
    if (-not $sdsInv.stamps -or @($sdsInv.stamps).Count -eq 0) {
        throw "SDS at '$sdsPath' returned 0 stamps for cloud '$Cloud'. Verify sds.$PipelineKey is correct."
    }
    foreach ($s in $sdsInv.stamps) {
        # SDS may carry only the short StampId (e.g. 'udc-01'); expand it to the
        # canonical stamp name using this cloud's ASC layout so ASC validation works.
        $sovLayout = "$(($ascData.Clouds | Where-Object { $_.Name -eq $Cloud } | Select-Object -First 1).Layout)"
        $sovName = if ($s.stampName) { "$($s.stampName)" } else { "$($s.stampId)" }
        $rawStamps.Add([PSCustomObject]@{
            stampName   = $(if ($useStampNaming) { ConvertFrom-SdsStampId -Name $sovName -Layout $sovLayout } else { "$($s.stampName)".ToLowerInvariant() })
            clusterType = $null
            cloudHint   = $Cloud
            layoutHint  = $null
            source      = 'sds'
        })
    }
}
else {
    # production (public cloud): run kusto.production query
    $k = $config.kusto.production
    if (-not $k -or -not $k.cluster -or -not $k.database -or -not $k.queryFile) {
        throw "service-config.json → kusto.production (cluster/database/queryFile) is required for Scope=production."
    }
    $queryPath = Join-Path $QueriesDir $k.queryFile
    if (-not (Test-Path $queryPath)) { throw "Kusto query file not found: $queryPath" }
    $queryText = Get-Content $queryPath -Raw

    $serviceFilter = if ($k.serviceFilter) { $k.serviceFilter } else { '1 == 1' }
    $stampPrefixFilter = '1 == 1'
    if ($k.stampPrefixFilter) {
        if ($k.stampPrefixFilter -is [string]) {
            $stampPrefixFilter = $k.stampPrefixFilter
        } elseif (@($k.stampPrefixFilter).Count -gt 0) {
            $stampPrefixFilter = ($k.stampPrefixFilter | ForEach-Object { "StampName startswith '$_'" }) -join ' or '
        }
    }
    $queryText = $queryText.Replace('{{SERVICE_FILTER}}', $serviceFilter)
    $queryText = $queryText.Replace('{{STAMP_PREFIX_FILTER}}', $stampPrefixFilter)
    if ($k.queryVariables) {
        foreach ($qv in $k.queryVariables.PSObject.Properties) {
            $queryText = $queryText.Replace("{{$($qv.Name)}}", "$($qv.Value)")
        }
    }

    $token = az account get-access-token --resource $k.cluster --query accessToken -o tsv 2>$null
    if (-not $token) { throw "Failed to acquire Kusto token for $($k.cluster). Run 'az login' (Repair-AzAuth.ps1)." }
    $startedAt = Get-Date
    $resp = Invoke-RestMethod -Uri (($k.cluster.TrimEnd('/')) + "/v1/rest/query") -Method POST `
        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -Body (@{ db = $k.database; csl = $queryText } | ConvertTo-Json -Depth 4) -ErrorAction Stop
    $primary = $resp.Tables[0]
    $colNames = @($primary.Columns | ForEach-Object { $_.ColumnName })
    $rows = foreach ($r in $primary.Rows) {
        $obj = [ordered]@{}
        for ($i = 0; $i -lt $colNames.Count; $i++) { $obj[$colNames[$i]] = $r[$i] }
        [PSCustomObject]$obj
    }
    $kustoMeta = [PSCustomObject]@{
        ranAt       = $startedAt.ToUniversalTime().ToString('o')
        durationMs  = [int]((Get-Date) - $startedAt).TotalMilliseconds
        rowCount    = @($rows).Count
        cluster     = $k.cluster
        database    = $k.database
        queryFile   = $k.queryFile
    }

    if (-not $rows -or @($rows).Count -eq 0) {
        throw "kusto.production query returned 0 rows. Refusing to publish an empty production inventory. Validate the query at $queryPath."
    }

    # Cluster-type extraction (per-row, not per-set).
    $extraction = if ($k.clusterTypeExtraction) { $k.clusterTypeExtraction } else { [PSCustomObject]@{ mode = 'deployment-unit-substring' } }

    foreach ($row in $rows) {
        $norm = ConvertTo-BaseStampName -Name "$($row.StampName)"
        $stampName = $norm.name
        if (-not $stampName) { continue }
        if ($norm.partition) {
            $foldedPartitions.Add([PSCustomObject]@{ from = "$($row.StampName)".ToLowerInvariant(); to = $stampName })
        }
        $ct = Resolve-RowClusterType -Row $row -Extraction $extraction -DefaultSubstrings $defaultClusterTypeSubstrings -Strict
        $rawStamps.Add([PSCustomObject]@{
            stampName   = $stampName
            clusterType = $ct
            cloudHint   = $null
            layoutHint  = $null
            source      = 'kusto'
        })
    }
}

# ── Enrich + drift detection ──────────────────────────────────────────
$stamps = [System.Collections.Generic.List[object]]::new()
$drift  = [System.Collections.Generic.List[object]]::new()
$seen   = [System.Collections.Generic.HashSet[string]]::new()

foreach ($rs in $rawStamps) {
    if (-not $seen.Add($rs.stampName)) { continue }
    $parts = Resolve-StampParts -Name $rs.stampName
    if (-not $parts) {
        $drift.Add([PSCustomObject]@{ stampName = $rs.stampName; reason = "stamp name does not match grammar '{shortName}-{layout}-{stampTag}{index}'" })
        continue
    }
    if ($parts.serviceTag -ne $stampTag) {
        $drift.Add([PSCustomObject]@{ stampName = $rs.stampName; reason = "serviceTag '$($parts.serviceTag)' != service.stampTag '$stampTag'" })
        continue
    }
    $cl = Resolve-CloudForStamp -Parts $parts
    if (-not $cl) {
        $drift.Add([PSCustomObject]@{ stampName = $rs.stampName; reason = "layout '$($parts.layout)' not found in any ASC cloud" })
        continue
    }
    $dc = $regionIndex["$($cl.Name)::$($parts.shortName)"]
    if (-not $dc) {
        $drift.Add([PSCustomObject]@{ stampName = $rs.stampName; reason = "shortName '$($parts.shortName)' not in cloud '$($cl.Name)' (layout '$($parts.layout)')"; cloud = $cl.Name })
        continue
    }
    # Canary scope: also validate cloud hint matches.
    if ($Scope -eq 'canary' -and $rs.cloudHint -and $cl.Name -ne $rs.cloudHint) {
        $drift.Add([PSCustomObject]@{ stampName = $rs.stampName; reason = "ASC-resolved cloud '$($cl.Name)' != owner-curated cloud '$($rs.cloudHint)'" })
        continue
    }
    # Production scope: apply optional -Cloud filter.
    if ($Scope -eq 'production' -and $Cloud -and $cl.Name -ne $Cloud) { continue }

    $stamps.Add([PSCustomObject]@{
        stampName     = $parts.stampName
        shortName     = $parts.shortName
        layout        = $parts.layout
        stampTag      = $parts.serviceTag
        index         = $parts.index
        clusterType   = $rs.clusterType
        cloud         = $cl.Name
        ev2RegionName = $dc.Ev2RegionName
        ev2Geography  = $dc.Ev2Geography
        dcRole        = @($dc.DatacenterType) -join ','
        source        = $rs.source
    })
}

# ── Lazy clusterType resolution for canary (multi-cloud) ──────────────
# When inventory.canary.stamps[].clusterType is null AND
# pipeline-catalog.json → canaryRouting.mode == 'cluster-type' AND
# service-config.json → kusto.canary.{cluster,database,queryFile} are set,
# run the Phase 4b detection query and join by stampName so the resolver
# in Steps 5/7/10 gets clusterType-tagged stamps without setup-service ever
# prompting the owner for it.
if ($Scope -eq 'canary' -and $stamps.Count -gt 0) {
    $needsResolve = @($stamps | Where-Object { -not $_.clusterType -or "$($_.clusterType)".Trim().Length -eq 0 })
    if ($needsResolve.Count -gt 0) {
        $kc = $config.kusto.canary
        $catalogPath = Join-Path $repoRoot '.github\skills\zed-agent\pipeline-catalog.json'
        $canaryMode = $null
        if (Test-Path $catalogPath) {
            try {
                $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
                if ($catalog.canaryRouting -and $catalog.canaryRouting.mode) {
                    $canaryMode = "$($catalog.canaryRouting.mode)".ToLowerInvariant()
                }
            } catch {
                Write-Verbose "Get-StampInventory: pipeline-catalog.json parse failed; skipping lazy canary clusterType resolve. $_"
            }
        }
        $kustoConfigured = $kc -and $kc.cluster -and $kc.database -and $kc.queryFile
        if ($canaryMode -eq 'cluster-type' -and $kustoConfigured) {
            $queryPath = Join-Path $QueriesDir $kc.queryFile
            if (-not (Test-Path $queryPath)) {
                Write-Warning "Phase 4b query file not found: $queryPath — leaving canary clusterType unresolved."
            } else {
                $queryText = Get-Content $queryPath -Raw
                $serviceFilter = if ($kc.serviceFilter) { $kc.serviceFilter } else { '1 == 1' }
                $stampPrefixFilter = '1 == 1'
                if ($kc.stampPrefixFilter) {
                    if ($kc.stampPrefixFilter -is [string]) {
                        $stampPrefixFilter = $kc.stampPrefixFilter
                    } elseif (@($kc.stampPrefixFilter).Count -gt 0) {
                        $stampPrefixFilter = ($kc.stampPrefixFilter | ForEach-Object { "StampName startswith '$_'" }) -join ' or '
                    }
                }
                $queryText = $queryText.Replace('{{SERVICE_FILTER}}', $serviceFilter)
                $queryText = $queryText.Replace('{{STAMP_PREFIX_FILTER}}', $stampPrefixFilter)
                if ($kc.queryVariables) {
                    foreach ($qv in $kc.queryVariables.PSObject.Properties) {
                        $queryText = $queryText.Replace("{{$($qv.Name)}}", "$($qv.Value)")
                    }
                }
                $token = az account get-access-token --resource $kc.cluster --query accessToken -o tsv 2>$null
                if (-not $token) {
                    Write-Warning "Failed to acquire Kusto token for $($kc.cluster) — leaving canary clusterType unresolved. Run 'az login' (Repair-AzAuth.ps1)."
                } else {
                    $kStarted = Get-Date
                    try {
                        $kResp = Invoke-RestMethod -Uri (($kc.cluster.TrimEnd('/')) + "/v1/rest/query") -Method POST `
                            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
                            -Body (@{ db = $kc.database; csl = $queryText } | ConvertTo-Json -Depth 4) -ErrorAction Stop
                    } catch {
                        Write-Warning "Phase 4b Kusto query failed — leaving canary clusterType unresolved. $_"
                        $kResp = $null
                    }
                    if ($kResp) {
                        $kPrimary = $kResp.Tables[0]
                        $kCols = @($kPrimary.Columns | ForEach-Object { $_.ColumnName })
                        $kRows = foreach ($r in $kPrimary.Rows) {
                            $obj = [ordered]@{}
                            for ($i = 0; $i -lt $kCols.Count; $i++) { $obj[$kCols[$i]] = $r[$i] }
                            [PSCustomObject]$obj
                        }
                        $extraction = if ($kc.clusterTypeExtraction) { $kc.clusterTypeExtraction } else { [PSCustomObject]@{ mode = 'deployment-unit-substring' } }
                        $stampMap = @{}
                        foreach ($row in $kRows) {
                            $rowStamp = (ConvertTo-BaseStampName -Name "$($row.StampName)").name
                            if (-not $rowStamp) { continue }
                            $rowCt = Resolve-RowClusterType -Row $row -Extraction $extraction -DefaultSubstrings $defaultClusterTypeSubstrings
                            if ($rowCt) { $stampMap[$rowStamp] = $rowCt }
                            if ($rowCt) { $stampMap[$rowStamp] = $rowCt }
                        }
                        foreach ($st in $stamps) {
                            if ((-not $st.clusterType -or "$($st.clusterType)".Trim().Length -eq 0) -and $stampMap.ContainsKey($st.stampName)) {
                                $st.clusterType = $stampMap[$st.stampName]
                            }
                        }
                        $kustoMeta = [PSCustomObject]@{
                            ranAt      = $kStarted.ToUniversalTime().ToString('o')
                            durationMs = [int]((Get-Date) - $kStarted).TotalMilliseconds
                            rowCount   = @($kRows).Count
                            cluster    = $kc.cluster
                            database   = $kc.database
                            queryFile  = $kc.queryFile
                            purpose    = 'canary-lazy-clusterType-resolve'
                        }
                    }
                }
            }
        }
    }
}

# ── Slice regions actually in use ─────────────────────────────────────
$inUseKeys = @($stamps | ForEach-Object { "$($_.cloud)::$($_.shortName)" } | Sort-Object -Unique)
$regions = @(
    foreach ($k in $inUseKeys) {
        $dc = $regionIndex[$k]
        $parts = $k -split '::', 2
        [PSCustomObject]@{
            cloud         = $parts[0]
            shortName     = $parts[1]
            ev2RegionName = $dc.Ev2RegionName
            ev2Geography  = $dc.Ev2Geography
            layout        = ($ascData.Clouds | Where-Object { $_.Name -eq $parts[0] } | Select-Object -First 1).Layout
            dcRole        = @($dc.DatacenterType) -join ','
        }
    }
)

# ── Effective cloud for the result envelope ───────────────────────────
$effectiveCloud = $null
if ($Scope -eq 'canary') {
    # Multi-cloud canary: return the distinct set of clouds that the resolved
    # stamps actually live in. Single-cloud services produce a one-element array.
    $effectiveCloud = @($stamps | ForEach-Object { $_.cloud } | Sort-Object -Unique)
    if ($effectiveCloud.Count -eq 1) { $effectiveCloud = $effectiveCloud[0] }
}
elseif ($Scope -eq 'production' -and $Cloud) { $effectiveCloud = $Cloud }

$stampSource = if ($Scope -eq 'canary') { 'config' } elseif ($isSovereignCloud) { 'sds' } else { 'kusto' }
$sourcesObj = [PSCustomObject]@{
    stamps    = $stampSource
    ascSource = $asc.source
    ascPath   = $asc.path
    fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
}
# Generic.List -> Object[] must go via the pipeline; a bare @($list) cast can
# trip "Argument types do not match" inside Add-Member / PSCustomObject in pwsh.
$stampsOut  = @($stamps  | ForEach-Object { $_ })
$regionsOut = @($regions | ForEach-Object { $_ })
$driftOut   = @($drift   | ForEach-Object { $_ })
$result = New-Object PSObject
$result | Add-Member -NotePropertyName scope        -NotePropertyValue $Scope
$result | Add-Member -NotePropertyName cloud        -NotePropertyValue $effectiveCloud
$result | Add-Member -NotePropertyName pipelineKey  -NotePropertyValue $PipelineKey
$result | Add-Member -NotePropertyName stampTag     -NotePropertyValue $stampTag
$result | Add-Member -NotePropertyName stamps       -NotePropertyValue $stampsOut
$result | Add-Member -NotePropertyName regions      -NotePropertyValue $regionsOut
$result | Add-Member -NotePropertyName drift        -NotePropertyValue $driftOut
$result | Add-Member -NotePropertyName sources      -NotePropertyValue $sourcesObj
$result | Add-Member -NotePropertyName kusto        -NotePropertyValue $kustoMeta
$result | Add-Member -NotePropertyName stampNaming  -NotePropertyValue ([PSCustomObject]@{
    partitionSuffixPattern = $partitionSuffixPattern
    sdsStampIdPattern      = $sdsStampIdPattern
    foldedPartitions       = @($foldedPartitions | ForEach-Object { $_ })
})
# ── SDS reconciliation (production scope only) ───────────────────────────────
if ($sdsReconcileEnabled) {
    $sdsScript = Join-Path $PSScriptRoot 'Get-StampInventoryFromSds.ps1'
    if (-not (Test-Path $sdsScript)) { throw "Get-StampInventoryFromSds.ps1 sibling script missing at $sdsScript." }
    $sdsPath = if ($sdsEntry.localClonePath -and (Test-Path (Join-Path $sdsEntry.localClonePath $sdsEntry.path))) {
        Join-Path $sdsEntry.localClonePath $sdsEntry.path
    } else {
        Join-Path $repoRoot $sdsEntry.path
    }
    if (-not (Test-Path $sdsPath)) {
        Write-Warning "SDS reconciliation skipped — file not found at '$sdsPath'. Ensure the repo clone is at '$repoRoot' or set sds.$PipelineKey.localClonePath."
    } else {
        $sdsArgs = @{ SdsPath = $sdsPath; ServiceConfigPath = $ServiceConfigPath }
        $sdsCloudForReconcile = if ($Cloud) { $Cloud } elseif ($isSovereignCloud) { $Cloud } else { $defaultCommercialCloud }
        if ($sdsCloudForReconcile) { $sdsArgs.Cloud = $sdsCloudForReconcile }
        $sdsInv = & $sdsScript @sdsArgs
        $tolerance = if ($null -ne $config.inventory.driftToleranceCount) { [int]$config.inventory.driftToleranceCount } else { 0 }
        if (-not $useStampNaming) {
            # Default (no inventory.stampNaming): exact stamp-name match, unchanged behaviour.
            $sdsNames   = @($sdsInv.stamps | ForEach-Object { "$($_.stampName)".ToLowerInvariant() }) | Sort-Object -Unique
            $kustoNames = @($stampsOut | ForEach-Object { $_.stampName }) | Sort-Object -Unique
            $sdsSet   = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sdsNames), [System.StringComparer]::OrdinalIgnoreCase)
            $kustoSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($kustoNames), [System.StringComparer]::OrdinalIgnoreCase)
            $sdsOnly   = @($sdsNames   | Where-Object { -not $kustoSet.Contains($_) })
            $kustoOnly = @($kustoNames | Where-Object { -not $sdsSet.Contains($_) })
            $driftCount = $sdsOnly.Count + $kustoOnly.Count
            $reconcile = [PSCustomObject]@{
                hash             = $sdsInv.hash
                source           = $sdsPath
                stampCount       = @($sdsInv.stamps).Count
                cloud            = $sdsCloudForReconcile
                sdsOnly          = $sdsOnly
                kustoOnly        = $kustoOnly
                driftCount       = $driftCount
                toleranceCount   = $tolerance
                withinTolerance  = ($driftCount -le $tolerance)
            }
        } else {
        # Compare like with like: only Kusto stamps that ASC resolved into the
        # SDS cloud being reconciled. Kusto stamps in other clouds (e.g. a
        # Canary-cloud stamp visible in the same Kusto table) are reported
        # as out-of-scope, not as drift — and cannot collide on the
        # cloud-local reconcile key.
        $kustoInScope  = @($stampsOut | Where-Object { -not $sdsCloudForReconcile -or $_.cloud -eq $sdsCloudForReconcile })
        $kustoOutScope = @($stampsOut | Where-Object { $sdsCloudForReconcile -and $_.cloud -ne $sdsCloudForReconcile } |
            ForEach-Object { [PSCustomObject]@{ stampName = $_.stampName; cloud = $_.cloud } })
        # Match on Get-StampReconcileKey so SDS short ids ('acl-01') and Kusto
        # full names ('acl-pod01-coord1') of the same stamp pair up.
        $sdsKeyed = @($sdsInv.stamps | ForEach-Object {
            $nm = if ($_.stampName) { "$($_.stampName)" } else { "$($_.stampId)" }
            [PSCustomObject]@{ name = $nm.ToLowerInvariant(); key = Get-StampReconcileKey -Name $nm }
        })
        $kustoKeyed = @($kustoInScope | ForEach-Object {
            [PSCustomObject]@{ name = $_.stampName; key = Get-StampReconcileKey -Name $_.stampName }
        })
        $sdsKeySet   = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sdsKeyed   | ForEach-Object { $_.key }), [System.StringComparer]::OrdinalIgnoreCase)
        $kustoKeySet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($kustoKeyed | ForEach-Object { $_.key }), [System.StringComparer]::OrdinalIgnoreCase)
        $sdsOnly   = @($sdsKeyed   | Where-Object { -not $kustoKeySet.Contains($_.key) } | ForEach-Object { $_.name } | Sort-Object -Unique)
        $kustoOnly = @($kustoKeyed | Where-Object { -not $sdsKeySet.Contains($_.key) }   | ForEach-Object { $_.name } | Sort-Object -Unique)
        $matchedCount = @($kustoKeyed | Where-Object { $sdsKeySet.Contains($_.key) }).Count
        $driftCount = $sdsOnly.Count + $kustoOnly.Count
        $reconcile = [PSCustomObject]@{
            hash             = $sdsInv.hash
            source           = $sdsPath
            stampCount       = @($sdsInv.stamps).Count
            cloud            = $sdsCloudForReconcile
            matchedBy        = 'reconcileKey {shortName}-{index} (inventory.stampNaming)'
            matchedCount     = $matchedCount
            sdsOnly          = $sdsOnly
            kustoOnly        = $kustoOnly
            kustoOutOfScope  = @($kustoOutScope)
            driftCount       = $driftCount
            toleranceCount   = $tolerance
            withinTolerance  = ($driftCount -le $tolerance)
        }
        }
        $result | Add-Member -NotePropertyName sdsReconciliation -NotePropertyValue $reconcile
        foreach ($n in $sdsOnly)   { $driftOut += [PSCustomObject]@{ stampName = $n; side = 'sdsOnly';   reason = "present in SDS but not in Kusto result" } }
        foreach ($n in $kustoOnly) { $driftOut += [PSCustomObject]@{ stampName = $n; side = 'kustoOnly'; reason = "present in Kusto but not in SDS"        } }
        $result.drift = $driftOut
    }
} elseif ($isSovereignCloud) {
    # Sovereign cloud path already used SDS as the source; surface the hash so
    # the inventory approval gate has something to compare against.
    $sdsScript = Join-Path $PSScriptRoot 'Get-StampInventoryFromSds.ps1'
    $sdsPath = if ($sdsEntry.localClonePath -and (Test-Path (Join-Path $sdsEntry.localClonePath $sdsEntry.path))) {
        Join-Path $sdsEntry.localClonePath $sdsEntry.path
    } else {
        Join-Path $repoRoot $sdsEntry.path
    }
    $sdsInv = & $sdsScript -SdsPath $sdsPath -Cloud $Cloud -ServiceConfigPath $ServiceConfigPath
    $result | Add-Member -NotePropertyName sdsReconciliation -NotePropertyValue ([PSCustomObject]@{
        hash            = $sdsInv.hash
        source          = $sdsPath
        stampCount      = @($sdsInv.stamps).Count
        cloud           = $Cloud
        sdsOnly         = @()
        kustoOnly       = @()
        driftCount      = 0
        toleranceCount  = 0
        withinTolerance = $true
    })
}

# ── Persist cache ─────────────────────────────────────────────────────
try {
    $cacheDir = Split-Path $InventoryCachePath -Parent
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $InventoryCachePath -Encoding utf8
} catch {
    Write-Warning "Failed to write inventory cache to $InventoryCachePath : $($_.Exception.Message)"
}

return $result
