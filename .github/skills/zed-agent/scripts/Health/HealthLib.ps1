<#
.SYNOPSIS
    Pure helper library for the ZED release health check (no I/O, no network).

.DESCRIPTION
    Dot-source this file. Every function is deterministic for its inputs so the
    detection and verdict rules can be unit-tested and replayed. Service-specific
    knowledge (tables, columns, markers, thresholds) never lives here — it comes
    from the service's release-health skill (health-config.json + KQL).

    Contents:
      Statistics      Get-HealthNormalCdf, Test-HealthProportion, Test-HealthRate, Set-HealthQValue
      KQL helpers     ConvertTo-HealthKqlString, ConvertTo-HealthKqlList, ConvertTo-HealthKqlDatetime,
                      ConvertTo-HealthKqlSignatureExpression, Expand-HealthQuery, Get-HealthAdxLink
      Text            ConvertTo-HealthSignature
      Classification  Get-HealthErrorClass
      Versions        Get-HealthReleaseVersion
      Cohorts         Get-HealthCohorts, Get-HealthWindows
      Comparisons     Measure-HealthComparison, Test-HealthInvestigate, Test-HealthSev1
      Signals         Measure-HealthOutcomes, Measure-HealthLatency, Measure-HealthSignatures,
                      Resolve-HealthNewSignatures, Measure-HealthCounters, Measure-HealthSeries,
                      Measure-HealthLifecycle
      Verdict         New-HealthFinding, Test-HealthSuppressed, Get-HealthVerdict
#>

Set-StrictMode -Off

# ───────────────────────────── Statistics ─────────────────────────────

function Get-HealthNormalCdf {
    param([double]$Z)
    $t = 1 / (1 + 0.2316419 * [math]::Abs($Z))
    $d = 0.3989422804014327 * [math]::Exp(-$Z * $Z / 2)
    $p = $d * $t * (0.319381530 + $t * (-0.356563782 + $t * (1.781477937 + $t * (-1.821255978 + $t * 1.330274429))))
    if ($Z -gt 0) { 1 - $p } else { $p }
}

# One-sided test that Count/Total is HIGHER than BaseCount/BaseTotal (two-proportion z-test).
function Test-HealthProportion {
    param([double]$Count, [double]$Total, [double]$BaseCount, [double]$BaseTotal)
    if ($Total -le 0 -or $BaseTotal -le 0) {
        return [pscustomobject]@{ rate = $null; baseRate = $null; ratio = $null; absDelta = $null; extra = 0.0; p = 1.0 }
    }
    $r1 = $Count / $Total; $r2 = $BaseCount / $BaseTotal
    $pooled = ($Count + $BaseCount) / ($Total + $BaseTotal)
    $se = [math]::Sqrt([math]::Max($pooled * (1 - $pooled) * (1 / $Total + 1 / $BaseTotal), 1e-18))
    $ratio = if ($r2 -gt 0) { $r1 / $r2 } elseif ($r1 -gt 0) { 1e9 } else { 1.0 }
    [pscustomobject]@{ rate = $r1; baseRate = $r2; ratio = $ratio; absDelta = $r1 - $r2; extra = $Count - $r2 * $Total; p = 1 - (Get-HealthNormalCdf (($r1 - $r2) / $se)) }
}

# One-sided Poisson rate test with exposures (conditional binomial, normal approximation).
function Test-HealthRate {
    param([double]$Count, [double]$Exposure, [double]$BaseCount, [double]$BaseExposure)
    if ($Exposure -le 0 -or $BaseExposure -le 0) {
        return [pscustomobject]@{ rate = $null; baseRate = $null; ratio = $null; absDelta = $null; extra = 0.0; p = 1.0 }
    }
    $r1 = $Count / $Exposure; $r2 = $BaseCount / $BaseExposure
    $n = $Count + $BaseCount
    $p = 1.0
    if ($n -gt 0) {
        $q = $Exposure / ($Exposure + $BaseExposure)
        $z = ($Count - $n * $q) / [math]::Sqrt([math]::Max($n * $q * (1 - $q), 1e-9))
        $p = 1 - (Get-HealthNormalCdf $z)
    }
    $ratio = if ($r2 -gt 0) { $r1 / $r2 } elseif ($r1 -gt 0) { 1e9 } else { 1.0 }
    [pscustomobject]@{ rate = $r1; baseRate = $r2; ratio = $ratio; absDelta = $r1 - $r2; extra = $Count - $r2 * $Exposure; p = $p }
}

# Benjamini–Hochberg: adds/overwrites a `q` property on every object that has `p`.
function Set-HealthQValue {
    param([object[]]$Tests)
    $valid = @($Tests | Where-Object { $_ -and $null -ne $_.p })
    $m = $valid.Count
    if ($m -eq 0) { return }
    $sorted = @($valid | Sort-Object { [double]$_.p })
    $prev = 1.0
    for ($i = $m - 1; $i -ge 0; $i--) {
        $q = [math]::Min($prev, [double]$sorted[$i].p * $m / ($i + 1))
        $sorted[$i] | Add-Member -NotePropertyName q -NotePropertyValue $q -Force
        $prev = $q
    }
}

# ───────────────────────────── KQL helpers ─────────────────────────────

function ConvertTo-HealthKqlString {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    "'" + ([string]$Value).Replace('\', '\\').Replace("'", "\'") + "'"
}

function ConvertTo-HealthKqlList {
    param([string[]]$Values)
    'dynamic([' + ((@($Values | Where-Object { $null -ne $_ }) | ForEach-Object { ConvertTo-HealthKqlString $_ }) -join ', ') + '])'
}

function ConvertTo-HealthKqlDatetime {
    param([datetime]$Value)
    'datetime(' + $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + ')'
}

<#
  {{TIME_FILTER}}: a KQL predicate on TIMESTAMP that covers only the windows' time ranges (overlapping
  ranges merged). Much cheaper than MIN_TIME..MAX_TIME, which spans the week between previousWeek and now.
#>
function ConvertTo-HealthKqlTimeFilter {
    param([object[]]$Windows, [string]$Column = 'TIMESTAMP', [int]$PadMinutes = 0)
    $ranges = @($Windows | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ S = (Get-HealthUtc $_.WStart).AddMinutes(-$PadMinutes); E = (Get-HealthUtc $_.WEnd).AddMinutes($PadMinutes) } } | Sort-Object S)
    if (-not $ranges.Count) { return 'false' }
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $ranges) {
        if ($merged.Count -and $r.S -le $merged[-1].E) { if ($r.E -gt $merged[-1].E) { $merged[-1].E = $r.E } }
        else { $merged.Add([pscustomobject]@{ S = $r.S; E = $r.E }) }
    }
    '(' + ((@($merged) | ForEach-Object { "$Column between ($(ConvertTo-HealthKqlDatetime $_.S) .. $(ConvertTo-HealthKqlDatetime $_.E))" }) -join ' or ') + ')'
}

<#
  {{WINDOWS_WIDE}} / {{WINDOW_CASE}}: one row per unit with every window's bounds, for a 1:1
  `lookup kind=inner ({{WINDOWS_WIDE}}) on Unit | extend Window = {{WINDOW_CASE}} | where isnotempty(Window)`.
  Unlike joining {{WINDOWS}} (one row per unit x window), rows are never duplicated before the time filter,
  which keeps large raw joins (e.g. error traces) within Kusto's memory budget.
#>
function ConvertTo-HealthKqlWindowsWide {
    param([object[]]$Windows)
    $names = 'current', 'previousDay', 'previousWeek'
    $cols = 'Unit:string, Cohort:string, ' + (($names | ForEach-Object { "${_}Start:datetime, ${_}End:datetime" }) -join ', ')
    $rows = foreach ($g in (@($Windows | Where-Object { $_ }) | Group-Object Unit)) {
        $vals = @((ConvertTo-HealthKqlString $g.Name), (ConvertTo-HealthKqlString ([string]$g.Group[0].Cohort)))
        foreach ($n in $names) {
            $w = @($g.Group | Where-Object Window -eq $n) | Select-Object -First 1
            if ($w) { $vals += (ConvertTo-HealthKqlDatetime (Get-HealthUtc $w.WStart)); $vals += (ConvertTo-HealthKqlDatetime (Get-HealthUtc $w.WEnd)) }
            else { $vals += 'datetime(null)'; $vals += 'datetime(null)' }
        }
        $vals -join ', '
    }
    "datatable($cols)[`n" + (@($rows) -join ",`n") + "`n]"
}

function Get-HealthKqlWindowCase {
    param([string]$Column = 'TIMESTAMP')
    "case($Column between (currentStart .. currentEnd), 'current', $Column between (previousDayStart .. previousDayEnd), 'previousDay', $Column between (previousWeekStart .. previousWeekEnd), 'previousWeek', '')"
}

# Builds a KQL expression that normalizes `$Column` into a stable error signature
# using the same rules as ConvertTo-HealthSignature (order matters).
function ConvertTo-HealthKqlSignatureExpression {
    param([object[]]$Rules, [string]$Column = 'Message', [int]$SourceLength = 400, [int]$MaxLength = 160)
    $expr = "substring($Column, 0, $SourceLength)"
    foreach ($r in @($Rules)) {
        $pattern = [string]$r.pattern
        $replacement = if ($null -ne $r.replacement) { [string]$r.replacement } else { '#' }
        $expr = "replace_regex($expr, @'" + $pattern.Replace("'", "''") + "', " + (ConvertTo-HealthKqlString $replacement) + ')'
    }
    "substring(trim(@'\s+', $expr), 0, $MaxLength)"
}

function ConvertTo-HealthSignature {
    param([string]$Text, [object[]]$Rules, [int]$SourceLength = 400, [int]$MaxLength = 160)
    $s = if ($Text.Length -gt $SourceLength) { $Text.Substring(0, $SourceLength) } else { $Text }
    foreach ($r in @($Rules)) {
        $replacement = if ($null -ne $r.replacement) { [string]$r.replacement } else { '#' }
        $s = [regex]::Replace($s, [string]$r.pattern, $replacement.Replace('$', '$$'))
    }
    $s = $s.Trim()
    if ($s.Length -gt $MaxLength) { $s.Substring(0, $MaxLength) } else { $s }
}

# Replaces {{NAME}} placeholders; throws when a placeholder is left unresolved.
function Expand-HealthQuery {
    param([Parameter(Mandatory)][string]$Query, [hashtable]$Values = @{})
    # Whole-line // comments are dropped first: a placeholder mentioned in a comment would otherwise expand into
    # multi-line text (e.g. a datatable) and break the query.
    $out = (($Query -split "`r?`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    foreach ($k in $Values.Keys) { $out = $out.Replace('{{' + $k + '}}', [string]$Values[$k]) }
    $left = @([regex]::Matches($out, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object Value | Sort-Object -Unique)
    if ($left.Count) { throw "Unresolved query placeholder(s): $($left -join ', ')" }
    $out
}

# Azure Data Explorer deep link (query gzip-compressed and base64-encoded, as the web UI expects).
function Get-HealthAdxLink {
    param([string]$Cluster, [string]$Database, [string]$Query)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Query)
    $ms = [IO.MemoryStream]::new()
    $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $clusterName = ([uri]$Cluster).Host -replace '\.kusto\.windows\.net$', ''
    "https://dataexplorer.azure.com/clusters/$clusterName/databases/$([uri]::EscapeDataString($Database))?query=$([uri]::EscapeDataString($b64))"
}

# ───────────────────────────── Classification ─────────────────────────────

# Returns 'success' (no error code), 'user', 'service' or 'unclassified'.
function Get-HealthErrorClass {
    param([string]$Code, [hashtable]$UserErrorMap, $Classification)
    if ([string]::IsNullOrWhiteSpace($Code)) { return 'success' }
    if ($Classification -and $Classification.overrides) {
        $ov = $Classification.overrides
        $hit = if ($ov -is [hashtable]) { $ov[$Code] } else { $ov.PSObject.Properties[$Code].Value }
        if ($hit) { return [string]$hit }
    }
    $nullCodes = @('null', 'none', 'success')
    if ($Classification -and $Classification.PSObject.Properties['nullCodes']) { $nullCodes = @($Classification.nullCodes) }
    if ($Code.ToLowerInvariant() -in $nullCodes) { return 'unclassified' }
    if ($UserErrorMap -and $UserErrorMap.ContainsKey($Code)) { return $(if ($UserErrorMap[$Code]) { 'user' } else { 'service' }) }
    if ($Classification -and $Classification.userErrorRegex -and $Code -match [string]$Classification.userErrorRegex) { return 'user' }
    'unclassified'
}

# ───────────────────────────── Versions ─────────────────────────────

function Get-HealthReleaseVersion {
    param([Parameter(Mandatory)][string]$BuildNumber, [string]$Branch, $VersionConfig)
    $format = if ($VersionConfig -and $VersionConfig.format) { [string]$VersionConfig.format } else { '{buildNumber}-{branch}' }
    $sanitize = if ($VersionConfig -and $VersionConfig.branchSanitizeRegex) { [string]$VersionConfig.branchSanitizeRegex } else { '[^A-Za-z0-9]' }
    $repl = if ($VersionConfig -and $null -ne $VersionConfig.branchReplacement) { [string]$VersionConfig.branchReplacement } else { '_' }
    $b = ([string]$Branch) -replace '^refs/heads/', ''
    $b = [regex]::Replace($b, $sanitize, $repl)
    $format.Replace('{buildNumber}', $BuildNumber).Replace('{branch}', $b)
}

# ───────────────────────────── Cohorts & windows ─────────────────────────────

function Get-HealthUtc {
    param([object]$Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

<#
  Rows: Unit, Version, FirstSeen, LastSeen, Ops (one row per unit × version over the lookback).
  Release units  = units that run the exact release version (T0 = first telemetry from it).
  Control units  = units whose latest official version is the previous version and that are still active.
  Waves          = release units grouped by T0 (gap > WaveGapMinutes starts a new wave); canary units form one wave.
#>
function Get-HealthCohorts {
    param(
        [object[]]$Rows,
        [Parameter(Mandatory)][string]$ReleaseVersion,
        [string]$PreviousVersion,
        $Scope,
        [datetime]$AsOf = [datetime]::UtcNow,
        [int]$WaveGapMinutes = 180,
        [hashtable]$StageMap = @{},
        [int]$ActiveWithinMinutes = 180
    )
    $AsOf = $AsOf.ToUniversalTime()
    $excluded = @(); if ($Scope -and $Scope.excludeVersionPatterns) { $excluded = @($Scope.excludeVersionPatterns) }
    $official = if ($Scope -and $Scope.officialVersionPattern) { [string]$Scope.officialVersionPattern } else { '.' }
    $unitRegex = if ($Scope -and $Scope.unitRegex) { [string]$Scope.unitRegex } else { '.' }
    $canary = @(); if ($Scope -and $Scope.canaryUnits) { $canary = @($Scope.canaryUnits) }
    $prefixRegex = if ($Scope -and $Scope.unitPrefixRegex) { [string]$Scope.unitPrefixRegex } else { '^([^-]+)' }

    $isOfficial = { param($v) ($v -match $official) -and -not (@($excluded | Where-Object { $v -match $_ }).Count) }
    $units = @()
    foreach ($g in (@($Rows) | Where-Object { $_.Unit -match $unitRegex } | Group-Object Unit)) {
        $rows = @($g.Group | ForEach-Object { [pscustomobject]@{ Version = [string]$_.Version; First = Get-HealthUtc $_.FirstSeen; Last = Get-HealthUtc $_.LastSeen; Ops = [double]$_.Ops } } | Where-Object { $_.First -le $AsOf })
        if (-not $rows.Count) { continue }
        $prefix = if ($g.Name -match $prefixRegex) { $Matches[1] } else { $g.Name }
        $rel = $rows | Where-Object Version -eq $ReleaseVersion | Select-Object -First 1
        if ($rel) {
            $before = @($rows | Where-Object { $_.Version -ne $ReleaseVersion -and (& $isOfficial $_.Version) -and $_.First -lt $rel.First } | Sort-Object Last -Descending)
            $units += [pscustomobject]@{ Unit = $g.Name; Prefix = $prefix; Status = 'release'; T0 = $rel.First; Version = $ReleaseVersion
                PreviousVersion = if ($before.Count) { $before[0].Version } else { $null }; IsCanary = $g.Name -in $canary; Stage = $StageMap[$g.Name]; LastSeen = $rel.Last }
        } else {
            $latest = @($rows | Where-Object { & $isOfficial $_.Version } | Sort-Object Last -Descending)
            $status = 'candidate'
            if (-not $latest.Count) { $latest = @($rows | Sort-Object Last -Descending); $status = 'excluded' }
            $units += [pscustomobject]@{ Unit = $g.Name; Prefix = $prefix; Status = $status; T0 = $null; Version = $latest[0].Version
                PreviousVersion = $null; IsCanary = $g.Name -in $canary; Stage = $StageMap[$g.Name]; LastSeen = $latest[0].Last }
        }
    }
    $release = @($units | Where-Object Status -eq 'release' | Sort-Object T0)
    if (-not $PreviousVersion) {
        $PreviousVersion = @($release | Where-Object PreviousVersion | Group-Object PreviousVersion | Sort-Object Count -Descending | Select-Object -First 1).Name
    }
    foreach ($u in ($units | Where-Object Status -eq 'candidate')) {
        $active = $u.LastSeen -ge $AsOf.AddMinutes(-$ActiveWithinMinutes)
        $u.Status = if ($PreviousVersion -and $u.Version -eq $PreviousVersion -and $active -and -not $u.IsCanary) { 'control' } else { 'excluded' }
    }

    # Waves (canary first, then T0 gaps).
    $waves = [System.Collections.Generic.List[object]]::new()
    $can = @($release | Where-Object IsCanary)
    if ($can.Count) {
        $waves.Add([pscustomobject]@{ Id = 'canary'; Label = 'Canary'; IsCanary = $true; Units = @($can.Unit); T0First = ($can | Sort-Object T0 | Select-Object -First 1).T0; T0Last = ($can | Sort-Object T0 | Select-Object -Last 1).T0 })
    }
    $groups = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new(); $last = $null
    foreach ($u in ($release | Where-Object { -not $_.IsCanary })) {
        if ($last -and ($u.T0 - $last).TotalMinutes -gt $WaveGapMinutes) { $groups.Add($current.ToArray()); $current = [System.Collections.Generic.List[object]]::new() }
        $current.Add($u); $last = $u.T0
    }
    if ($current.Count) { $groups.Add($current.ToArray()) }
    $n = 0
    foreach ($grp in $groups) {
        $n++
        $labels = @($grp | Where-Object Stage | Group-Object Stage | Sort-Object Count -Descending)
        $waves.Add([pscustomobject]@{ Id = 'wave-' + $grp[0].T0.ToString('yyyyMMddTHHmm'); Label = $(if ($labels.Count) { $labels[0].Name } else { "Wave $n" }); IsCanary = $false
            Units = @($grp.Unit); T0First = $grp[0].T0; T0Last = $grp[-1].T0 })
    }

    [pscustomobject]@{
        ReleaseVersion  = $ReleaseVersion
        PreviousVersion = $PreviousVersion
        Units           = $units
        Release         = $release
        Control         = @($units | Where-Object Status -eq 'control')
        Excluded        = @($units | Where-Object Status -eq 'excluded')
        Waves           = $waves.ToArray()
    }
}

<#
  Comparison windows for release units and control units. Every release unit gets:
    current       = T0 + offset .. min(T0 + maxWindow, AsOf - lag)
    previousDay   = the same length one day earlier (on the previous build), ending before T0
    previousWeek  = the same hours seven days earlier
  Control units get the same windows anchored on the release units' median T0.
  Returns rows: Unit, Cohort ('release'|'control'), Window, WStart, WEnd.
#>
function Get-HealthWindows {
    param(
        [object[]]$ReleaseUnits,
        [object[]]$ControlUnits,
        [datetime]$AsOf = [datetime]::UtcNow,
        $Timing,
        [string[]]$Windows = @('current', 'previousDay', 'previousWeek')
    )
    $offset = if ($Timing -and $null -ne $Timing.windowStartOffsetMinutes) { [double]$Timing.windowStartOffsetMinutes } else { 15 }
    $maxH = if ($Timing -and $Timing.maxWindowHours) { [double]$Timing.maxWindowHours } else { 24 }
    $lag = if ($Timing -and $null -ne $Timing.ingestionLagMinutes) { [double]$Timing.ingestionLagMinutes } else { 20 }
    $AsOf = $AsOf.ToUniversalTime()
    $rows = [System.Collections.Generic.List[object]]::new()
    $make = {
        param($unit, $cohort, [datetime]$t0)
        $s = $t0.AddMinutes($offset)
        $e = @($t0.AddHours($maxH), $AsOf.AddMinutes(-$lag)) | Sort-Object | Select-Object -First 1
        if ($e -le $s) { return }
        $len = $e - $s
        # previousDay must end before T0 so it never contains the new build.
        $pdEnd = @($e.AddDays(-1), $t0.AddMinutes(-5)) | Sort-Object | Select-Object -First 1
        $pdStart = $pdEnd - $len
        foreach ($w in $Windows) {
            switch ($w) {
                'current'      { $rows.Add([pscustomobject]@{ Unit = $unit; Cohort = $cohort; Window = 'current'; WStart = $s; WEnd = $e }) }
                'previousDay'  { $rows.Add([pscustomobject]@{ Unit = $unit; Cohort = $cohort; Window = 'previousDay'; WStart = $pdStart; WEnd = $pdEnd }) }
                'previousWeek' { $rows.Add([pscustomobject]@{ Unit = $unit; Cohort = $cohort; Window = 'previousWeek'; WStart = $s.AddDays(-7); WEnd = $e.AddDays(-7) }) }
            }
        }
    }
    foreach ($u in @($ReleaseUnits)) { & $make $u.Unit 'release' (Get-HealthUtc $u.T0) }
    $t0s = @($ReleaseUnits | ForEach-Object { Get-HealthUtc $_.T0 } | Sort-Object)
    if ($t0s.Count) {
        $anchor = $t0s[[int][math]::Floor(($t0s.Count - 1) / 2)]
        foreach ($c in @($ControlUnits)) { & $make $c.Unit 'control' $anchor }
    }
    $rows.ToArray()
}

# ───────────────────────────── Comparisons ─────────────────────────────

<#
  Compares the release cohort's current window with its baseline window, and the control
  cohort's change over the same windows (difference-in-differences). Pass ControlCount -1
  when no usable control exists.
#>
function Measure-HealthComparison {
    param(
        [double]$Count, [double]$Exposure, [double]$BaseCount, [double]$BaseExposure,
        [double]$ControlCount = -1, [double]$ControlExposure = 0, [double]$ControlBaseCount = -1, [double]$ControlBaseExposure = 0,
        [ValidateSet('proportion', 'rate')][string]$Test = 'proportion'
    )
    $t = if ($Test -eq 'proportion') { Test-HealthProportion $Count $Exposure $BaseCount $BaseExposure } else { Test-HealthRate $Count $Exposure $BaseCount $BaseExposure }
    $ctlRatio = $null
    if ($ControlCount -ge 0 -and $ControlExposure -gt 0 -and $ControlBaseCount -ge 0 -and $ControlBaseExposure -gt 0) {
        $cr = ($ControlCount / $ControlExposure); $cb = ($ControlBaseCount / $ControlBaseExposure)
        $ctlRatio = if ($cb -gt 0) { $cr / $cb } elseif ($cr -gt 0) { 1e9 } else { 1.0 }
    }
    $did = if ($null -eq $ctlRatio -or $null -eq $t.ratio) { $t.ratio } elseif ($ctlRatio -eq 0) { 1e9 } else { $t.ratio / $ctlRatio }
    [pscustomobject]@{
        count = $Count; exposure = $Exposure; baseCount = $BaseCount; baseExposure = $BaseExposure
        rate = $t.rate; baseRate = $t.baseRate; ratio = $t.ratio; absDelta = $t.absDelta; extra = $t.extra; p = $t.p; q = $t.p
        controlRatio = $ctlRatio; did = $did
    }
}

function Test-HealthInvestigate {
    param($Comparison, $Rules)
    if (-not $Comparison -or $null -eq $Comparison.ratio) { return $false }
    $delta = if ($Rules -and $null -ne $Rules.relativeDelta) { [double]$Rules.relativeDelta } else { 0.10 }
    $maxQ = if ($Rules -and $null -ne $Rules.maxQ) { [double]$Rules.maxQ } else { 0.01 }
    $minExtra = if ($Rules -and $null -ne $Rules.minExtra) { [double]$Rules.minExtra } else { 20 }
    ($Comparison.ratio -ge 1 + $delta) -and ($Comparison.q -le $maxQ) -and ($Comparison.extra -ge $minExtra) -and
        ($null -eq $Comparison.did -or $Comparison.did -ge 1 + $delta)
}

function Test-HealthSev1 {
    param($Comparison, $Sev1)
    if (-not $Sev1 -or -not $Comparison -or $null -eq $Comparison.ratio) { return $false }
    $ok = $Comparison.ratio -ge [double]$Sev1.ratio
    if ($ok -and $null -ne $Sev1.absDelta) { $ok = $Comparison.absDelta -ge [double]$Sev1.absDelta }
    if ($ok -and $null -ne $Sev1.minExtra) { $ok = $Comparison.extra -ge [double]$Sev1.minExtra }
    $maxQ = if ($null -ne $Sev1.maxQ) { [double]$Sev1.maxQ } else { 0.001 }
    if ($ok) { $ok = $Comparison.q -le $maxQ }
    if ($ok -and $null -ne $Comparison.did) { $ok = $Comparison.did -ge [double]$Sev1.ratio }
    $ok
}

# ───────────────────────────── Findings ─────────────────────────────

function New-HealthFinding {
    param(
        [ValidateSet('Sev1', 'Investigate', 'Watch', 'Inconclusive')][string]$Severity,
        [string]$Area, [string]$SignalId, [string]$Title, [string]$Detail,
        [string]$Key, [string[]]$Units = @(), $Metrics, [string]$Attribution = 'release-correlated', [string]$QueryName
    )
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$SignalId|$Key"))
    $id = 'F-' + ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 10).ToLowerInvariant()
    [pscustomobject]@{ id = $id; severity = $Severity; area = $Area; signalId = $SignalId; key = $Key; title = $Title; detail = $Detail
        units = @($Units); metrics = $Metrics; attribution = $Attribution; query = $QueryName; suppressed = $null; rca = $null }
}

function Test-HealthSuppressed {
    param($Finding, [object[]]$Suppressions, [datetime]$AsOf = [datetime]::UtcNow)
    foreach ($s in @($Suppressions)) {
        if (-not $s) { continue }
        if ($s.expires -and (Get-HealthUtc $s.expires) -lt $AsOf.ToUniversalTime()) { continue }
        if ($s.signalId -and $s.signalId -ne $Finding.signalId) { continue }
        if ($s.keyRegex -and $Finding.key -notmatch [string]$s.keyRegex) { continue }
        if ($s.findingId -and $s.findingId -ne $Finding.id) { continue }
        if (-not $s.signalId -and -not $s.keyRegex -and -not $s.findingId) { continue }
        return $s
    }
    $null
}

# ───────────────────────────── Signal evaluation ─────────────────────────────

function Get-HealthRules {
    param($Comparison, $Signal)
    [pscustomobject]@{
        relativeDelta = if ($Signal.thresholds -and $null -ne $Signal.thresholds.relativeDelta) { $Signal.thresholds.relativeDelta } else { $Comparison.investigateRelativeDelta }
        maxQ          = if ($Signal.thresholds -and $null -ne $Signal.thresholds.maxQ) { $Signal.thresholds.maxQ } else { $Comparison.falseDiscoveryRate }
        minExtra      = if ($Signal.thresholds -and $null -ne $Signal.thresholds.minExtra) { $Signal.thresholds.minExtra } else { $Comparison.minExtraFailures }
    }
}

function Get-HealthSum {
    param([object[]]$Rows, [string]$Property)
    $s = 0.0
    foreach ($r in @($Rows)) { if ($r -and $null -ne $r.$Property -and "$($r.$Property)" -ne '') { $s += [double]$r.$Property } }
    $s
}

function Get-HealthShortText {
    param([string]$Text, [int]$Max = 90)
    if ($Text.Length -le $Max) { $Text } else { $Text.Substring(0, $Max - 3) + '...' }
}

function Format-HealthRatio {
    param($Value)
    if ($null -eq $Value) { 'n/a' } elseif ([double]$Value -ge 1e8) { 'new' } else { '{0:n2}x' -f $Value }
}

<#
  Outcome signals (operations with success/failure): Rows = Unit, Window, Operation, ErrorCode, Total, Failures,
  optional TopSubscriptionFailures. Each row is one (unit, window, operation, errorCode); the success row has
  ErrorCode ''. Classification turns error codes into user / service / unclassified (unclassified counts as service).
#>
function Measure-HealthOutcomes {
    param(
        [object[]]$Rows, $Signal, [hashtable]$UnitCohort, [hashtable]$UserErrorMap, $Classification, $Comparison,
        [string]$BaseWindow = 'previousDay', [string]$ConfirmWindow = 'previousWeek'
    )
    $rules = Get-HealthRules $Comparison $Signal
    $sev1 = if ($Signal.thresholds) { $Signal.thresholds.sev1 } else { $null }
    $minSamples = if ($Signal.thresholds -and $Signal.thresholds.minSamples) { [double]$Signal.thresholds.minSamples } else { 100 }
    $subShare = if ($Comparison.singleSubscriptionShare) { [double]$Comparison.singleSubscriptionShare } else { 0.8 }
    $minCodeCount = if ($Signal.thresholds -and $Signal.thresholds.newCodeMinCount) { [double]$Signal.thresholds.newCodeMinCount } else { 20 }
    $minCodeUnits = if ($Signal.thresholds -and $Signal.thresholds.newCodeMinUnits) { [int]$Signal.thresholds.newCodeMinUnits } else { 2 }
    $maxDrop = if ($Signal.thresholds -and $null -ne $Signal.thresholds.maxVolumeDrop) { [double]$Signal.thresholds.maxVolumeDrop } else { 0.30 }
    $area = if ($Signal.area) { [string]$Signal.area } else { [string]$Signal.title }
    $label = if ($Signal.title) { [string]$Signal.title } else { [string]$Signal.id }

    $rows = @(foreach ($r in @($Rows)) {
        $cohort = $UnitCohort[[string]$r.Unit]; if (-not $cohort) { continue }
        $class = if ([double]$r.Failures -gt 0) { Get-HealthErrorClass ([string]$r.ErrorCode) $UserErrorMap $Classification } else { 'success' }
        if ($class -eq 'success' -and [double]$r.Failures -gt 0) { $class = 'unclassified' }
        $top = if ($null -ne $r.TopSubscriptionFailures -and "$($r.TopSubscriptionFailures)" -ne '') { [double]$r.TopSubscriptionFailures } else { 0.0 }
        [pscustomobject]@{ Unit = [string]$r.Unit; Cohort = $cohort; Window = [string]$r.Window; Operation = [string]$r.Operation; ErrorCode = [string]$r.ErrorCode
            Total = [double]$r.Total; Failures = [double]$r.Failures; Top = $top; Class = $class }
    })
    $isSvc = { param($x) $x.Class -in 'service', 'unclassified' }
    $agg = {
        param([object[]]$set, [string]$cohort, [string]$window, [string]$what)
        $s = 0.0
        foreach ($x in $set) {
            if ($x.Cohort -ne $cohort -or $x.Window -ne $window) { continue }
            switch ($what) { 'total' { $s += $x.Total } 'service' { if (& $isSvc $x) { $s += $x.Failures } } 'user' { if ($x.Class -eq 'user') { $s += $x.Failures } } }
        }
        $s
    }
    $cmp = {
        param([object[]]$set, [string]$what, [string]$base)
        $ct = & $agg $set 'control' 'current' 'total'; $cbt = & $agg $set 'control' $base 'total'
        $ctlOk = $ct -gt 0 -and $cbt -gt 0
        Measure-HealthComparison -Count (& $agg $set 'release' 'current' $what) -Exposure (& $agg $set 'release' 'current' 'total') `
            -BaseCount (& $agg $set 'release' $base $what) -BaseExposure (& $agg $set 'release' $base 'total') `
            -ControlCount $(if ($ctlOk) { & $agg $set 'control' 'current' $what } else { -1 }) -ControlExposure $ct `
            -ControlBaseCount $(if ($ctlOk) { & $agg $set 'control' $base $what } else { -1 }) -ControlBaseExposure $cbt -Test proportion
    }

    $tests = [System.Collections.Generic.List[object]]::new()
    $overall = & $cmp $rows 'service' $BaseWindow; $tests.Add($overall)
    $overallWeek = & $cmp $rows 'service' $ConfirmWindow
    $user = & $cmp $rows 'user' $BaseWindow; $tests.Add($user)
    $vol = [pscustomobject]@{
        current = & $agg $rows 'release' 'current' 'total'; base = & $agg $rows 'release' $BaseWindow 'total'
        controlCurrent = & $agg $rows 'control' 'current' 'total'; controlBase = & $agg $rows 'control' $BaseWindow 'total'
    }
    $ops = @(foreach ($g in ($rows | Group-Object Operation)) {
        $c = & $cmp $g.Group 'service' $BaseWindow
        if ($c.exposure -lt $minSamples -or $c.baseExposure -lt $minSamples) { continue }
        $tests.Add($c); [pscustomobject]@{ operation = $g.Name; cmp = $c; rows = $g.Group }
    })
    $ctlSvcCur = & $agg $rows 'control' 'current' 'service'; $ctlSvcBase = & $agg $rows 'control' $BaseWindow 'service'
    $ctlUnitOk = $vol.controlCurrent -gt 0 -and $vol.controlBase -gt 0
    $units = @(foreach ($g in ($rows | Where-Object Cohort -eq 'release' | Group-Object Unit)) {
        $c = Measure-HealthComparison -Count (& $agg $g.Group 'release' 'current' 'service') -Exposure (& $agg $g.Group 'release' 'current' 'total') `
            -BaseCount (& $agg $g.Group 'release' $BaseWindow 'service') -BaseExposure (& $agg $g.Group 'release' $BaseWindow 'total') `
            -ControlCount $(if ($ctlUnitOk) { $ctlSvcCur } else { -1 }) -ControlExposure $vol.controlCurrent `
            -ControlBaseCount $(if ($ctlUnitOk) { $ctlSvcBase } else { -1 }) -ControlBaseExposure $vol.controlBase -Test proportion
        if ($c.exposure -lt $minSamples -or $c.baseExposure -lt $minSamples) { continue }
        $tests.Add($c); [pscustomobject]@{ unit = $g.Name; cmp = $c; rows = $g.Group }
    })
    $codes = @(foreach ($g in ($rows | Where-Object { $_.Failures -gt 0 -and (& $isSvc $_) } | Group-Object ErrorCode)) {
        $cur = @($g.Group | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq 'current' })
        $count = Get-HealthSum $cur 'Failures'; if ($count -le 0) { continue }
        $sum = { param($c, $w) Get-HealthSum @($g.Group | Where-Object { $_.Cohort -eq $c -and $_.Window -eq $w }) 'Failures' }
        $base = & $sum 'release' $BaseWindow; $week = & $sum 'release' $ConfirmWindow
        $ctlCur = & $sum 'control' 'current'; $ctlBase = & $sum 'control' $BaseWindow
        $ctlOk = $vol.controlCurrent -gt 0 -and $vol.controlBase -gt 0
        $c = Measure-HealthComparison -Count $count -Exposure $vol.current -BaseCount $base -BaseExposure $vol.base `
            -ControlCount $(if ($ctlOk) { $ctlCur } else { -1 }) -ControlExposure $vol.controlCurrent `
            -ControlBaseCount $(if ($ctlOk) { $ctlBase } else { -1 }) -ControlBaseExposure $vol.controlBase -Test rate
        $tests.Add($c)
        $top = ($cur | Measure-Object Top -Maximum).Maximum
        [pscustomobject]@{ code = $g.Name; class = $g.Group[0].Class; count = $count; base = $base; week = $week; controlCurrent = $ctlCur
            units = @($cur | Where-Object Failures -gt 0 | Select-Object -ExpandProperty Unit -Unique); topShare = $(if ($count -gt 0 -and $top) { $top / $count } else { 0 }); cmp = $c }
    })
    Set-HealthQValue -Tests $tests.ToArray()

    $findings = [System.Collections.Generic.List[object]]::new()
    $fmt = { param($c) '{0:p3} vs {1:p3} on the previous build ({2}; control {3}; q={4:g2})' -f $c.rate, $c.baseRate, (Format-HealthRatio $c.ratio), (Format-HealthRatio $c.controlRatio), $c.q }
    # One subscription in one (unit, operation, error code) cell explains most of the extra failures -> customer, not the build.
    $topShareOf = {
        param([object[]]$set, $c)
        if (-not $c -or [double]$c.extra -le 0) { return 0.0 }
        $top = 0.0
        foreach ($x in $set) { if ($x.Cohort -eq 'release' -and $x.Window -eq 'current' -and (& $isSvc $x) -and $x.Top -gt $top) { $top = $x.Top } }
        $top / [double]$c.extra
    }
    $addRate = {
        param([string]$sev, [string]$key, [string]$title, $c, [object[]]$set, [string[]]$units = @())
        $share = & $topShareOf $set $c
        if ($share -ge $subShare) {
            $findings.Add((New-HealthFinding -Severity Watch -Area $area -SignalId $Signal.id -Key $key -Units $units -Attribution 'single-subscription' -Title "$title (one subscription)" -Detail ("$(& $fmt $c); one subscription accounts for {0:p0} of the extra failures" -f [math]::Min($share, 1)) -Metrics $c -QueryName $Signal.id))
        } else {
            $findings.Add((New-HealthFinding -Severity $sev -Area $area -SignalId $Signal.id -Key $key -Units $units -Title $title -Detail (& $fmt $c) -Metrics $c -QueryName $Signal.id))
        }
    }
    if (Test-HealthSev1 $overall $sev1) { & $addRate Sev1 'overall' "$label service-failure rate up $(Format-HealthRatio $overall.ratio)" $overall $rows }
    elseif (Test-HealthInvestigate $overall $rules) { & $addRate Investigate 'overall' "$label service-failure rate up $('{0:p0}' -f ($overall.ratio - 1))" $overall $rows }
    $userRules = [pscustomobject]@{ relativeDelta = [math]::Max([double]$rules.relativeDelta, 0.5); maxQ = $rules.maxQ; minExtra = [double]$rules.minExtra * 5 }
    if (Test-HealthInvestigate $user $userRules) {
        $findings.Add((New-HealthFinding -Severity Investigate -Area $area -SignalId $Signal.id -Key 'user-errors' -Title "$label user-error rate up $('{0:p0}' -f ($user.ratio - 1)) (check for misclassified service failures)" -Detail (& $fmt $user) -Metrics $user -QueryName $Signal.id))
    }
    if ($vol.base -gt 0 -and $vol.current / $vol.base -le (1 - $maxDrop)) {
        $ctlVol = if ($vol.controlBase -gt 0) { $vol.controlCurrent / $vol.controlBase } else { 1.0 }
        if (($vol.current / $vol.base) / [math]::Max($ctlVol, 1e-9) -le (1 - $maxDrop)) {
            $findings.Add((New-HealthFinding -Severity Sev1 -Area $area -SignalId $Signal.id -Key 'volume' -Title "$label volume dropped to $('{0:p0}' -f ($vol.current / $vol.base)) of the previous build" -Detail ('{0:n0} vs {1:n0}; control {2:p0}' -f $vol.current, $vol.base, $ctlVol) -Metrics $vol -QueryName $Signal.id))
        }
    }
    foreach ($o in $ops) {
        $sevOp = if (Test-HealthSev1 $o.cmp $sev1) { 'Sev1' } elseif (Test-HealthInvestigate $o.cmp $rules) { 'Investigate' } else { $null }
        if ($sevOp) { & $addRate $sevOp "op|$($o.operation)" "$label $($o.operation) service failures up $(Format-HealthRatio $o.cmp.ratio)" $o.cmp $o.rows }
    }
    foreach ($u in $units) {
        if (Test-HealthInvestigate $u.cmp $rules) {
            & $addRate Investigate "unit|$($u.unit)" "$label service failures up $(Format-HealthRatio $u.cmp.ratio) on $($u.unit)" $u.cmp $u.rows @($u.unit)
        }
    }
    foreach ($c in $codes) {
        $isNew = $c.base -eq 0 -and $c.week -eq 0 -and $c.controlCurrent -eq 0
        $sev = $null
        if ($isNew -and $c.count -ge $minCodeCount -and $c.units.Count -ge $minCodeUnits) { $sev = 'Sev1' }
        elseif (-not $isNew -and (Test-HealthSev1 $c.cmp $sev1)) { $sev = 'Sev1' }
        elseif (-not $isNew -and (Test-HealthInvestigate $c.cmp $rules)) { $sev = 'Investigate' }
        if (-not $sev) { continue }
        $detail = '{0:n0} failures on {1} unit(s) vs {2:n0} on the previous build (normalized {3}; control {4}; q={5:g2})' -f $c.count, $c.units.Count, $c.base, (Format-HealthRatio $c.cmp.ratio), (Format-HealthRatio $c.cmp.controlRatio), $c.cmp.q
        if ($c.topShare -ge $subShare) {
            $findings.Add((New-HealthFinding -Severity Watch -Area $area -SignalId $Signal.id -Key "code|$($c.code)" -Units $c.units -Attribution 'single-subscription' -Title "$label $($c.code) concentrated in one subscription" -Detail ("$detail; {0:p0} from one subscription" -f $c.topShare) -Metrics $c.cmp -QueryName $Signal.id))
        } else {
            $title = if ($isNew) { "New $($c.class) error code $($c.code) on the new build" } else { "$label error $($c.code) up $(Format-HealthRatio $c.cmp.ratio)" }
            $findings.Add((New-HealthFinding -Severity $sev -Area $area -SignalId $Signal.id -Key "code|$($c.code)" -Units $c.units -Title $title -Detail $detail -Metrics $c.cmp -QueryName $Signal.id))
        }
    }
    [pscustomobject]@{
        signalId = $Signal.id; title = $label; area = $area; kind = 'outcomes'
        summary = [pscustomobject]@{ serviceRate = $overall.rate; baseServiceRate = $overall.baseRate; ratio = $overall.ratio; controlRatio = $overall.controlRatio; weekRatio = $overallWeek.ratio
            userRate = $user.rate; baseUserRate = $user.baseRate; volume = $vol.current; baseVolume = $vol.base }
        status = if (@($findings | Where-Object severity -eq 'Sev1').Count) { 'fail' } elseif (@($findings | Where-Object severity -eq 'Investigate').Count) { 'warn' } else { 'pass' }
        findings = $findings.ToArray(); topCodes = @($codes | Sort-Object count -Descending | Select-Object -First 10 code, class, count, base, week, controlCurrent, topShare)
    }
}

<# Latency: Rows = Cohort, Window, Operation, N, P50, P95 (cohort-level percentiles). #>
function Measure-HealthLatency {
    param([object[]]$Rows, $Signal, $Comparison, [string]$BaseWindow = 'previousDay')
    $rel = if ($Signal.thresholds -and $null -ne $Signal.thresholds.relativeDelta) { [double]$Signal.thresholds.relativeDelta } else { [double]$Comparison.investigateRelativeDelta }
    $minN = if ($Signal.thresholds -and $Signal.thresholds.minSamples) { [double]$Signal.thresholds.minSamples } else { 1000 }
    $minMs = if ($Signal.thresholds -and $null -ne $Signal.thresholds.minDeltaMs) { [double]$Signal.thresholds.minDeltaMs } else { 50 }
    $pct = if ($Signal.thresholds -and $Signal.thresholds.percentile) { 'P' + $Signal.thresholds.percentile } else { 'P95' }
    $findings = [System.Collections.Generic.List[object]]::new()
    $ops = @(foreach ($g in (@($Rows) | Group-Object Operation)) {
        $get = { param($c, $w) $g.Group | Where-Object { $_.Cohort -eq $c -and $_.Window -eq $w } | Select-Object -First 1 }
        $cur = & $get 'release' 'current'; $base = & $get 'release' $BaseWindow
        if (-not $cur -or -not $base -or [double]$cur.N -lt $minN -or [double]$base.$pct -le 0) { continue }
        $ratio = [double]$cur.$pct / [double]$base.$pct
        $cc = & $get 'control' 'current'; $cb = & $get 'control' $BaseWindow
        $ctl = if ($cc -and $cb -and [double]$cb.$pct -gt 0) { [double]$cc.$pct / [double]$cb.$pct } else { $null }
        $o = [pscustomobject]@{ operation = $g.Name; n = [double]$cur.N; value = [double]$cur.$pct; base = [double]$base.$pct; ratio = $ratio; controlRatio = $ctl }
        if ($ratio -ge 1 + $rel -and ($o.value - $o.base) -ge $minMs -and ($null -eq $ctl -or $ratio / [math]::Max($ctl, 1e-9) -ge 1 + $rel)) {
            $findings.Add((New-HealthFinding -Severity Investigate -Area $Signal.area -SignalId $Signal.id -Key "op|$($g.Name)" -Title "$($Signal.title) $($g.Name) $pct up $('{0:p0}' -f ($ratio - 1))" `
                -Detail ('{0:n0} ms vs {1:n0} ms on the previous build; control {2}; {3:n0} calls' -f $o.value, $o.base, (Format-HealthRatio $ctl), $o.n) -Metrics $o -QueryName $Signal.id))
        }
        $o
    })
    [pscustomobject]@{ signalId = $Signal.id; title = $Signal.title; area = $Signal.area; kind = 'latency'
        summary = [pscustomobject]@{ operations = $ops.Count; worstRatio = ($ops | Measure-Object ratio -Maximum).Maximum }
        status = if ($findings.Count) { 'warn' } else { 'pass' }; findings = $findings.ToArray(); operations = $ops }
}

<#
  Error signatures: Rows = Cohort, Window, Signature, Count, Stamps, Instances [, TopSubscriptionCount].
  Exposure = hashtable "<cohort>|<window>" -> operations (normalizes counts across windows of different volume).
  Signatures on fewer than minUnits units, or concentrated in one subscription, are customer/stamp noise.
  Returns findings plus `candidates` that look new and must be checked against the lookback history.
#>
function Measure-HealthSignatures {
    param([object[]]$Rows, $Signal, $Comparison, [hashtable]$Exposure, [string]$BaseWindow = 'previousDay')
    $rules = Get-HealthRules $Comparison $Signal
    $sev1 = if ($Signal.thresholds) { $Signal.thresholds.sev1 } else { $null }
    $minUnits = if ($Signal.thresholds -and $Signal.thresholds.minUnits) { [int]$Signal.thresholds.minUnits } else { 2 }
    $minNew = if ($Signal.thresholds -and $Signal.thresholds.newMinCount) { [double]$Signal.thresholds.newMinCount } else { 20 }
    $subShare = if ($Comparison.singleSubscriptionShare) { [double]$Comparison.singleSubscriptionShare } else { 0.8 }
    $ignore = if ($Signal.PSObject.Properties['ignoreSignatureRegex'] -and $Signal.ignoreSignatureRegex) { [string]$Signal.ignoreSignatureRegex } else { $null }
    $exp = { param($c, $w) [double]$Exposure["$c|$w"] }
    $ctlOk = (& $exp 'control' 'current') -gt 0 -and (& $exp 'control' $BaseWindow) -gt 0
    $tests = [System.Collections.Generic.List[object]]::new()
    $index = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)   # signatures are case-sensitive (as in KQL)
    foreach ($r in @($Rows)) { $index["$($r.Cohort)|$($r.Window)|$($r.Signature)"] = $r }
    $items = @(foreach ($cur in (@($Rows) | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq 'current' })) {
        $sig = [string]$cur.Signature
        $base = $index["release|$BaseWindow|$sig"]; $cc = $index["control|current|$sig"]; $cb = $index["control|$BaseWindow|$sig"]
        $count = [double]$cur.Count
        $c = Measure-HealthComparison -Count $count -Exposure (& $exp 'release' 'current') -BaseCount ([double]$base.Count) -BaseExposure (& $exp 'release' $BaseWindow) `
            -ControlCount $(if ($ctlOk) { [double]$cc.Count } else { -1 }) -ControlExposure (& $exp 'control' 'current') `
            -ControlBaseCount $(if ($ctlOk) { [double]$cb.Count } else { -1 }) -ControlBaseExposure (& $exp 'control' $BaseWindow) -Test rate
        $tests.Add($c)
        $top = if ($null -ne $cur.TopSubscriptionCount -and "$($cur.TopSubscriptionCount)" -ne '') { [double]$cur.TopSubscriptionCount } else { 0 }
        [pscustomobject]@{ signature = $sig; count = $count; units = [int]$cur.Stamps; instances = [int]$cur.Instances; base = [double]$base.Count
            controlCurrent = [double]$cc.Count; topShare = $(if ($count -gt 0) { $top / $count } else { 0 }); cmp = $c
            isNewInWindows = ([double]$base.Count -eq 0 -and [double]$cc.Count -eq 0 -and [double]$cb.Count -eq 0) }
    })
    Set-HealthQValue -Tests $tests.ToArray()
    $findings = [System.Collections.Generic.List[object]]::new()
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $items) {
        if ($i.units -lt $minUnits -or $i.topShare -ge $subShare) { continue }
        if ($ignore -and $i.signature -match $ignore) { continue }
        if ($i.isNewInWindows) { if ($i.count -ge $minNew) { $candidates.Add($i) }; continue }
        $sev = if (Test-HealthSev1 $i.cmp $sev1) { 'Sev1' } elseif (Test-HealthInvestigate $i.cmp $rules) { 'Investigate' } else { $null }
        if ($sev) {
            $findings.Add((New-HealthFinding -Severity $sev -Area $Signal.area -SignalId $Signal.id -Key "sig|$($i.signature)" -Title "Error signature up $(Format-HealthRatio $i.cmp.ratio) on $($i.units) units: $(Get-HealthShortText $i.signature)" `
                -Detail ('{0:n0} vs {1:n0} on the previous build (per-op normalized); control {2}; q={3:g2}: {4}' -f $i.count, $i.base, (Format-HealthRatio $i.cmp.controlRatio), $i.cmp.q, $i.signature) -Metrics $i.cmp -QueryName $Signal.id))
        }
    }
    $relTotal = Get-HealthSum @($Rows | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq 'current' }) 'Count'
    $relBase = Get-HealthSum @($Rows | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq $BaseWindow }) 'Count'
    $overall = Measure-HealthComparison -Count $relTotal -Exposure (& $exp 'release' 'current') -BaseCount $relBase -BaseExposure (& $exp 'release' $BaseWindow) -Test rate
    [pscustomobject]@{ signalId = $Signal.id; title = $Signal.title; area = $Signal.area; kind = 'signatures'
        summary = [pscustomobject]@{ errorsPerMillionOps = $(if ($overall.rate) { 1e6 * $overall.rate } else { 0 }); baseErrorsPerMillionOps = $(if ($overall.baseRate) { 1e6 * $overall.baseRate } else { 0 }); ratio = $overall.ratio; signatures = $items.Count }
        status = if (@($findings | Where-Object severity -eq 'Sev1').Count) { 'fail' } elseif ($findings.Count) { 'warn' } else { 'pass' }
        findings = $findings.ToArray(); candidates = $candidates.ToArray() }
}

<# History rows: Signature, Count — occurrences on any other build over the lookback. #>
function Resolve-HealthNewSignatures {
    param($Result, [object[]]$HistoryRows, $Signal)
    $seen = [System.Collections.Generic.Dictionary[string, double]]::new([StringComparer]::Ordinal); foreach ($h in @($HistoryRows)) { if ($h -and [double]$h.Count -gt 0) { $seen[[string]$h.Signature] = [double]$h.Count } }
    $added = @(foreach ($c in @($Result.candidates)) {
        if ($seen.ContainsKey($c.signature)) { continue }
        New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "sig|$($c.signature)" `
            -Title "New error signature on $($c.units) units: $(Get-HealthShortText $c.signature)" -Detail ('{0:n0} occurrences on {1} units / {2} instances: {3}' -f $c.count, $c.units, $c.instances, $c.signature) -Metrics $c.cmp -QueryName $Signal.id
    })
    $Result.findings = @($Result.findings) + $added
    if ($added.Count) { $Result.status = 'fail' }
    $Result | Add-Member -NotePropertyName preExistingCandidates -NotePropertyValue @($Result.candidates | Where-Object { $seen.ContainsKey($_.signature) } | Select-Object signature, count, units) -Force
    $Result
}

<#
  Counters: Rows = Unit, Window, RoleInstance, Counter, Avg, P95, Min, Max.
  Signal.counters = [{ name, label, rule: 'p95-shift'|'avg-shift'|'floor', ceiling, floor, relativeDelta, minDelta }]
#>
function Measure-HealthCounters {
    param([object[]]$Rows, $Signal, [hashtable]$UnitCohort, $Comparison, [string]$BaseWindow = 'previousDay')
    $findings = [System.Collections.Generic.List[object]]::new()
    $summary = [ordered]@{}
    foreach ($rule in @($Signal.counters)) {
        $set = @($Rows | Where-Object { $_.Counter -eq $rule.name -and $UnitCohort[[string]$_.Unit] })
        $rel = if ($null -ne $rule.relativeDelta) { [double]$rule.relativeDelta } else { [double]$Comparison.investigateRelativeDelta }
        $minDelta = if ($null -ne $rule.minDelta) { [double]$rule.minDelta } else { 0 }
        $field = if ($rule.rule -eq 'avg-shift') { 'Avg' } else { 'P95' }
        $label = if ($rule.label) { [string]$rule.label } else { [string]$rule.name }
        $mean = { param([object[]]$sub) $v = @($sub | ForEach-Object { [double]$_.$field }); if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null } }
        $cohortSlice = { param($c, $w) @($set | Where-Object { $UnitCohort[[string]$_.Unit] -eq $c -and $_.Window -eq $w }) }
        $ctlRatio = $null; $ccv = & $mean (& $cohortSlice 'control' 'current'); $cbv = & $mean (& $cohortSlice 'control' $BaseWindow)
        if ($ccv -and $cbv) { $ctlRatio = $ccv / $cbv }
        $relCurSet = & $cohortSlice 'release' 'current'
        $relCur = & $mean $relCurSet; $relBase = & $mean (& $cohortSlice 'release' $BaseWindow)
        $summary[$label] = [pscustomobject]@{ current = $relCur; base = $relBase; ratio = $(if ($relBase) { $relCur / $relBase } else { $null }); controlRatio = $ctlRatio
            minValue = ($relCurSet | Measure-Object Min -Minimum).Minimum; maxP95 = ($relCurSet | Measure-Object P95 -Maximum).Maximum }
        foreach ($u in (@($set | Where-Object { $UnitCohort[[string]$_.Unit] -eq 'release' }) | Select-Object -ExpandProperty Unit -Unique)) {
            $uCur = @($set | Where-Object { $_.Unit -eq $u -and $_.Window -eq 'current' })
            if ($rule.rule -eq 'floor') {
                $min = ($uCur | Measure-Object Min -Minimum).Minimum
                if ($null -ne $min -and $min -lt [double]$rule.floor) {
                    $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "floor|$($rule.name)|$u" -Units @($u) -Title "$label below $($rule.floor) on $u" -Detail ('minimum {0:n0}' -f $min) -QueryName $Signal.id))
                }
                continue
            }
            $cur = & $mean $uCur; $base = & $mean @($set | Where-Object { $_.Unit -eq $u -and $_.Window -eq $BaseWindow })
            if ($null -eq $cur) { continue }
            if ($rule.ceiling -and $cur -ge [double]$rule.ceiling) {
                $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "ceiling|$($rule.name)|$u" -Units @($u) -Title "$label at or above $($rule.ceiling) on $u" -Detail ('{0:n1} ({1}, mean over instances)' -f $cur, $field) -QueryName $Signal.id))
            } elseif ($base -and $cur / $base -ge 1 + $rel -and ($cur - $base) -ge $minDelta -and ($null -eq $ctlRatio -or ($cur / $base) / [math]::Max($ctlRatio, 1e-9) -ge 1 + $rel)) {
                $findings.Add((New-HealthFinding -Severity Investigate -Area $Signal.area -SignalId $Signal.id -Key "shift|$($rule.name)|$u" -Units @($u) -Title "$label up $('{0:p0}' -f ($cur / $base - 1)) on $u" -Detail ('{0:n1} vs {1:n1} on the previous build; control {2}' -f $cur, $base, (Format-HealthRatio $ctlRatio)) -QueryName $Signal.id))
            }
        }
    }
    [pscustomobject]@{ signalId = $Signal.id; title = $Signal.title; area = $Signal.area; kind = 'counters'; summary = [pscustomobject]$summary
        status = if (@($findings | Where-Object severity -eq 'Sev1').Count) { 'fail' } elseif ($findings.Count) { 'warn' } else { 'pass' }; findings = $findings.ToArray() }
}

<# Counter series (current window only): Rows = Unit, Role, Counter, Bucket, Avg. Flags sustained growth (leaks). #>
function Measure-HealthSeries {
    param([object[]]$Rows, $Signal, [hashtable]$UnitCohort)
    $maxGrowth = if ($Signal.thresholds -and $null -ne $Signal.thresholds.maxGrowthPctPerHour) { [double]$Signal.thresholds.maxGrowthPctPerHour } else { 2 }
    $minHours = if ($Signal.thresholds -and $Signal.thresholds.minHours) { [int]$Signal.thresholds.minHours } else { 6 }
    $findings = [System.Collections.Generic.List[object]]::new()
    $slopes = @(foreach ($g in (@($Rows) | Where-Object { $UnitCohort[[string]$_.Unit] -eq 'release' } | Group-Object Unit, Role, Counter)) {
        $pts = @($g.Group | Sort-Object { Get-HealthUtc $_.Bucket })
        if ($pts.Count -lt $minHours) { continue }
        $t0 = Get-HealthUtc $pts[0].Bucket
        $xs = @($pts | ForEach-Object { ((Get-HealthUtc $_.Bucket) - $t0).TotalHours }); $ys = @($pts | ForEach-Object { [double]$_.Avg })
        $mx = ($xs | Measure-Object -Average).Average; $my = ($ys | Measure-Object -Average).Average
        $num = 0.0; $den = 0.0
        for ($i = 0; $i -lt $xs.Count; $i++) { $num += ($xs[$i] - $mx) * ($ys[$i] - $my); $den += ($xs[$i] - $mx) * ($xs[$i] - $mx) }
        if ($den -le 0 -or $my -eq 0) { continue }
        $growth = 100 * ($num / $den) / $my
        $s = [pscustomobject]@{ unit = $g.Group[0].Unit; role = $g.Group[0].Role; counter = $g.Group[0].Counter; hours = $pts.Count; growthPctPerHour = $growth }
        if ($growth -ge $maxGrowth) {
            $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "growth|$($s.unit)|$($s.role)|$($s.counter)" -Units @($s.unit) -Title "$($Signal.title) growing $('{0:n2}' -f $growth)%/h on $($s.unit) $($s.role)" -Detail "$($s.hours) hourly points" -QueryName $Signal.id))
        }
        $s
    })
    [pscustomobject]@{ signalId = $Signal.id; title = $Signal.title; area = $Signal.area; kind = 'series'
        summary = [pscustomobject]@{ maxGrowthPctPerHour = ($slopes | Measure-Object growthPctPerHour -Maximum).Maximum; top = @($slopes | Sort-Object growthPctPerHour -Descending | Select-Object -First 3) }
        status = if ($findings.Count) { 'fail' } else { 'pass' }; findings = $findings.ToArray() }
}

<#
  Upgrade lifecycle:
    Events        Unit, RoleInstance, Service, Event ('init'|'init-failed'|'stop-requested'|'stop-unrequested'), Version, Timestamp [, Pid]
    StartFailures Unit, Role, Version, Count, First, Sample
  Duplicate init lines from one restart are collapsed (same Pid, or within dedupeMinutes); a restart loop is
  `loopRestarts` initializations of one instance within `loopWindowMinutes`.
#>
function Measure-HealthLifecycle {
    param([object[]]$Events, [object[]]$StartFailures, [object[]]$ReleaseUnits, $Signal, [string]$ReleaseVersion)
    $dedupe = if ($Signal.thresholds -and $Signal.thresholds.dedupeMinutes) { [double]$Signal.thresholds.dedupeMinutes } else { 5 }
    $loopN = if ($Signal.thresholds -and $Signal.thresholds.loopRestarts) { [int]$Signal.thresholds.loopRestarts } else { 3 }
    $loopWin = if ($Signal.thresholds -and $Signal.thresholds.loopWindowMinutes) { [double]$Signal.thresholds.loopWindowMinutes } else { 60 }
    $findings = [System.Collections.Generic.List[object]]::new()
    $perUnit = @(foreach ($u in @($ReleaseUnits)) {
        $ev = @($Events | Where-Object Unit -eq $u.Unit)
        $inits = @($ev | Where-Object { $_.Event -eq 'init' -and $_.Version -eq $ReleaseVersion })
        $instances = @($inits | ForEach-Object { "$($_.RoleInstance)|$($_.Service)" } | Sort-Object -Unique)
        $maxInits = 0; $loopInstance = $null
        foreach ($g in ($inits | Group-Object RoleInstance, Service)) {
            $clusters = [System.Collections.Generic.List[object]]::new()
            foreach ($e in @($g.Group | Sort-Object { Get-HealthUtc $_.Timestamp })) {
                $t = Get-HealthUtc $e.Timestamp; $p = [string]$e.Pid
                $prev = if ($clusters.Count) { $clusters[$clusters.Count - 1] } else { $null }
                $dup = $prev -and ((($t - $prev.Time).TotalMinutes -le $dedupe) -or ($p -and $p -eq $prev.Pid))
                if (-not $dup) { $clusters.Add([pscustomobject]@{ Time = $t; Pid = $p }) }
            }
            for ($i = 0; $i -lt $clusters.Count; $i++) {
                $start = $clusters[$i].Time
                $inWin = @($clusters | Where-Object { $_.Time -ge $start -and ($_.Time - $start).TotalMinutes -le $loopWin }).Count
                if ($inWin -gt $maxInits) { $maxInits = $inWin; $loopInstance = $g.Name }
            }
        }
        $failedInit = @($ev | Where-Object { $_.Event -eq 'init-failed' -and $_.Version -eq $ReleaseVersion })
        $unrequested = @($ev | Where-Object { $_.Event -eq 'stop-unrequested' -and $_.Version -eq $ReleaseVersion })
        $starts = @($StartFailures | Where-Object { $_.Unit -eq $u.Unit -and $_.Version -eq $ReleaseVersion })
        if ($starts.Count) {
            $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "start-failure|$($u.Unit)" -Units @($u.Unit) -Title "Role start failure (role recycling) on $($u.Unit)" -Detail ('{0} occurrence(s): {1}' -f (Get-HealthSum $starts 'Count'), $starts[0].Sample) -QueryName $Signal.id))
        }
        if ($failedInit.Count) { $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "init-failed|$($u.Unit)" -Units @($u.Unit) -Title "Failed initialization on $($u.Unit)" -Detail "$($failedInit.Count) event(s)" -QueryName $Signal.id)) }
        if ($unrequested.Count) { $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "unrequested-stop|$($u.Unit)" -Units @($u.Unit) -Title "Unrequested stop of the new build on $($u.Unit)" -Detail "$($unrequested.Count) event(s)" -QueryName $Signal.id)) }
        if ($maxInits -ge $loopN) { $findings.Add((New-HealthFinding -Severity Sev1 -Area $Signal.area -SignalId $Signal.id -Key "restart-loop|$($u.Unit)" -Units @($u.Unit) -Title "Restart loop on $($u.Unit)" -Detail "$maxInits starts of $loopInstance within $loopWin min (duplicates within $dedupe min collapsed)" -QueryName $Signal.id)) }
        if (-not $inits.Count -and -not $starts.Count -and -not $failedInit.Count) {
            $findings.Add((New-HealthFinding -Severity Inconclusive -Area $Signal.area -SignalId $Signal.id -Key "no-lifecycle|$($u.Unit)" -Units @($u.Unit) -Attribution 'data-quality' -Title "No upgrade lifecycle events for $($u.Unit)" -Detail 'Telemetry gap or different logging; upgrade health could not be confirmed' -QueryName $Signal.id))
        }
        [pscustomobject]@{ unit = $u.Unit; initializedInstances = $instances.Count; maxStartsPerWindow = $maxInits; failedInit = $failedInit.Count; unrequestedStops = $unrequested.Count; startFailures = (Get-HealthSum $starts 'Count') }
    })
    [pscustomobject]@{ signalId = $Signal.id; title = $Signal.title; area = $Signal.area; kind = 'lifecycle'
        summary = [pscustomobject]@{ units = $perUnit.Count; unitsInitialized = @($perUnit | Where-Object initializedInstances -gt 0).Count; instances = Get-HealthSum $perUnit 'initializedInstances'; startFailures = Get-HealthSum $perUnit 'startFailures' }
        status = if (@($findings | Where-Object severity -eq 'Sev1').Count) { 'fail' } elseif ($findings.Count) { 'warn' } else { 'pass' }
        findings = $findings.ToArray(); units = $perUnit }
}

# ───────────────────────────── Verdict ─────────────────────────────

<#
  NO-GO        any open Sev1 finding attributed to the release
  INCONCLUSIVE data-quality blocker, or not enough bake/samples (and no Sev1)
  HOLD         any open Investigate finding (or Sev1 with uncertain attribution)
  GO           otherwise
  Accepted (health accept) and suppressed findings are reported but do not count.
#>
function Get-HealthVerdict {
    param([object[]]$Findings, [object[]]$DataQualityIssues, [bool]$BakeComplete = $true, [string[]]$AcceptedIds = @(), $Override)
    $open = @($Findings | Where-Object { $_ -and $_.id -notin $AcceptedIds -and -not $_.suppressed })
    $sev1 = @($open | Where-Object { $_.severity -eq 'Sev1' -and $_.attribution -eq 'release-correlated' })
    $inv = @($open | Where-Object { $_.severity -eq 'Investigate' -or ($_.severity -eq 'Sev1' -and $_.attribution -ne 'release-correlated') })
    $inc = @(@($open | Where-Object severity -eq 'Inconclusive') + @($DataQualityIssues | Where-Object { $_ }))
    $reasons = [System.Collections.Generic.List[string]]::new()
    $verdict = 'GO'
    if ($sev1.Count) { foreach ($f in $sev1) { $reasons.Add("Sev1: $($f.title)") }; $verdict = 'NO-GO' }
    elseif ($inc.Count) { foreach ($f in $inc) { $reasons.Add("Inconclusive: $(if ($f.title) { $f.title } else { [string]$f })") }; $verdict = 'INCONCLUSIVE' }
    elseif (-not $BakeComplete) { $reasons.Add('Minimum bake (workload cycles and hours) not reached yet'); $verdict = 'INCONCLUSIVE' }
    elseif ($inv.Count) { foreach ($f in $inv) { $reasons.Add("Investigate: $($f.title)") }; $verdict = 'HOLD' }
    else { $reasons.Add('No release-correlated regression on any signal') }
    if ($Override -and $Override.verdict) {
        $reasons.Add("Owner override to $($Override.verdict) by $($Override.decidedBy): $($Override.reason)")
        $verdict = [string]$Override.verdict
    }
    [pscustomobject]@{ verdict = $verdict; reasons = $reasons.ToArray()
        counts = [pscustomobject]@{ sev1 = $sev1.Count; investigate = $inv.Count; inconclusive = $inc.Count; watch = @($open | Where-Object severity -eq 'Watch').Count; accepted = @($Findings | Where-Object { $_ -and $_.id -in $AcceptedIds }).Count } }
}
