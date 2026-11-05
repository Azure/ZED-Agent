<#
.SYNOPSIS
    Validates a service's release-health skill: config schema, TODO placeholders, and a live
    dry run of every query against Kusto with its output-column contract.

.DESCRIPTION
    1. Get-HealthConfig (schema + referenced query files).
    2. Fails on leftover TODO markers in health-config.json or any referenced query.
    3. Unless -NoDryRun: runs the cohort query, picks the release build (-ReleaseVersion or the
       official build with the most recent operations) and up to 3 units on it plus up to 3 control
       units on another official build, builds short windows (last -WindowMinutes before now-lag,
       the same hours a day and a week earlier) and runs exposure, freshness, every enabled signal
       query (plus history / start-failure queries) and every RCA drill-down, checking columns.
    Used by setup-service group 11, `setup-service validate` and test-preflight.

.OUTPUTS
    @{ ok; issues[]; release; units; queries[{ name; file; ok; rows; seconds; missingColumns; error }] }
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$SkillPath,
    [string]$ReleaseVersion,
    [int]$WindowMinutes = 30,
    [switch]$NoDryRun,
    [scriptblock]$KqlInvoker
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HealthLib.ps1')
. (Join-Path $PSScriptRoot 'HealthKusto.ps1')
. (Join-Path $PSScriptRoot 'HealthConfig.ps1')
if (-not $RepoRoot) { $RepoRoot = Get-HealthRepoRoot }

$issues = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
try { $hc = Get-HealthConfig -RepoRoot $RepoRoot -SkillPath $SkillPath }
catch { return [pscustomobject]@{ ok = $false; issues = @("Config: $($_.Exception.Message)"); queries = @() } }
$cfg = $hc.Config

$cfgText = Get-Content -LiteralPath $hc.ConfigPath -Raw
foreach ($m in [regex]::Matches($cfgText, '"[^"]*\bTODO\b[^"]*"')) { $issues.Add("health-config.json still contains $($m.Value)") }
foreach ($f in $hc.Queries.Keys) { if ($hc.Queries[$f] -match '\bTODO') { $issues.Add("$f still contains TODO markers") } }
$blocking = $issues.Count
$skillMd = Join-Path $hc.SkillDir 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillMd)) { $issues.Add('SKILL.md is missing') }
elseif ((Get-Content -LiteralPath $skillMd -Raw) -match '\|\s*TODO\s*\|') { $issues.Add('SKILL.md still has TODO table rows (telemetry / signals)') }

$contracts = @{
    cohort = 'Unit', 'Version', 'FirstSeen', 'LastSeen', 'Ops'; exposure = 'Unit', 'Window', 'Version', 'Ops', 'Instances'; freshness = 'Source', 'Latest', 'LagMinutes'
    outcomes = 'Unit', 'Window', 'Operation', 'ErrorCode', 'Total', 'Failures'; latency = 'Cohort', 'Window', 'Operation', 'N', 'P50', 'P95'
    signatures = 'Cohort', 'Window', 'Signature', 'Count', 'Stamps', 'Instances'; history = 'Signature', 'Count'
    counters = 'Unit', 'Window', 'RoleInstance', 'Counter', 'Avg', 'P95', 'Min', 'Max'; series = 'Unit', 'Role', 'Counter', 'Bucket', 'Avg'
    lifecycle = 'Unit', 'RoleInstance', 'Service', 'Event', 'Version', 'Timestamp'; startFailures = 'Unit', 'Role', 'Version', 'Count', 'First', 'Sample'
}

if (-not $NoDryRun -and -not $blocking) {
    $now = [datetime]::UtcNow
    $run = {
        param([string]$Name, [string]$File, [hashtable]$Values, [string]$Contract)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = [ordered]@{ name = $Name; file = $File; ok = $false; rows = 0; seconds = 0; missingColumns = @(); error = $null }
        try {
            $text = Expand-HealthQuery -Query $hc.Queries[$File] -Values $Values
            $rows = if ($KqlInvoker) { @(& $KqlInvoker $Name $text) } else { @(Invoke-HealthKql -Cluster $cfg.dataSource.cluster -Database $cfg.dataSource.database -Query $text -TimeoutMinutes $cfg.dataSource.queryTimeoutMinutes) }
            $r.rows = $rows.Count
            if ($Contract -and $rows.Count) {
                $cols = @($rows[0].PSObject.Properties.Name)
                $r.missingColumns = @($contracts[$Contract] | Where-Object { $_ -notin $cols })
            }
            $r.ok = -not $r.missingColumns.Count
            $r.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $results.Add([pscustomobject]$r)
            return , $rows
        } catch {
            $r.error = $_.Exception.Message; $r.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $results.Add([pscustomobject]$r)
            return , @()
        }
    }
    $cohortRows = & $run 'cohort' $cfg.cohortQuery @{ LOOKBACK_START = ConvertTo-HealthKqlDatetime $now.AddDays(-2); AS_OF = ConvertTo-HealthKqlDatetime $now; RELEASE_VERSION = ConvertTo-HealthKqlString ([string]$ReleaseVersion) } 'cohort'
    $unitRx = if ($cfg.scope.unitRegex) { [string]$cfg.scope.unitRegex } else { '.' }
    $offRx = if ($cfg.scope.officialVersionPattern) { [string]$cfg.scope.officialVersionPattern } else { '.' }
    $excl = @($cfg.scope.excludeVersionPatterns | Where-Object { $_ })
    $official = @($cohortRows | Where-Object { $row = $_; ($row.Unit -match $unitRx) -and ([string]$row.Version -match $offRx) -and -not (@($excl | Where-Object { [string]$row.Version -match $_ }).Count) })
    if (-not $ReleaseVersion) { $ReleaseVersion = @($official | Group-Object Version | Sort-Object { ($_.Group | Measure-Object Ops -Sum).Sum } -Descending | Select-Object -First 1).Name }
    if (-not $ReleaseVersion) { $issues.Add('Cohort query returned no official build — check unitRegex / officialVersionPattern and the cohort query') }
    else {
        $relUnits = @($official | Where-Object Version -eq $ReleaseVersion | Sort-Object Ops -Descending | Select-Object -First 3 | ForEach-Object { [pscustomobject]@{ Unit = $_.Unit; T0 = $now.AddHours(-2) } })
        $ctlUnits = @($official | Where-Object { $_.Version -ne $ReleaseVersion -and $_.Unit -notin $relUnits.Unit } | Sort-Object Ops -Descending | Select-Object -First 3 | ForEach-Object { [pscustomobject]@{ Unit = $_.Unit } })
        $lag = [double]$cfg.timing.ingestionLagMinutes
        $end = $now.AddMinutes(-$lag); $start = $end.AddMinutes(-$WindowMinutes)
        $windows = foreach ($u in $relUnits) { foreach ($c in @(@('current', 0), @('previousDay', -1), @('previousWeek', -7))) { [pscustomobject]@{ Unit = $u.Unit; Cohort = 'release'; Window = $c[0]; WStart = $start.AddDays($c[1]); WEnd = $end.AddDays($c[1]) } } }
        $windows = @($windows) + @(foreach ($u in $ctlUnits) { foreach ($c in @(@('current', 0), @('previousDay', -1))) { [pscustomobject]@{ Unit = $u.Unit; Cohort = 'control'; Window = $c[0]; WStart = $start.AddDays($c[1]); WEnd = $end.AddDays($c[1]) } } })
        $wl = "datatable(Unit:string, Cohort:string, Window:string, WStart:datetime, WEnd:datetime)[`n" + ((@($windows) | ForEach-Object { "{0}, {1}, {2}, {3}, {4}" -f (ConvertTo-HealthKqlString $_.Unit), (ConvertTo-HealthKqlString $_.Cohort), (ConvertTo-HealthKqlString $_.Window), (ConvertTo-HealthKqlDatetime $_.WStart), (ConvertTo-HealthKqlDatetime $_.WEnd) }) -join ",`n") + "`n]"
        $base = @{
            UNITS = ConvertTo-HealthKqlList @($windows.Unit | Select-Object -Unique); RELEASE_UNITS = ConvertTo-HealthKqlList @($relUnits.Unit); CONTROL_UNITS = ConvertTo-HealthKqlList @($ctlUnits.Unit)
            WINDOWS = $wl; MIN_TIME = ConvertTo-HealthKqlDatetime ($start.AddDays(-7)); MAX_TIME = ConvertTo-HealthKqlDatetime $end; TIME_FILTER = ConvertTo-HealthKqlTimeFilter -Windows @($windows); WINDOWS_WIDE = ConvertTo-HealthKqlWindowsWide -Windows @($windows); WINDOW_CASE = Get-HealthKqlWindowCase
            T0S = "datatable(Unit:string, T0:datetime)[`n" + ((@($relUnits) | ForEach-Object { "{0}, {1}" -f (ConvertTo-HealthKqlString $_.Unit), (ConvertTo-HealthKqlDatetime $_.T0) }) -join ",`n") + "`n]"
            RELEASE_VERSION = ConvertTo-HealthKqlString $ReleaseVersion; PREVIOUS_VERSION = ConvertTo-HealthKqlString ''; AS_OF = ConvertTo-HealthKqlDatetime $now
            SIGNATURE_EXPR = ConvertTo-HealthKqlSignatureExpression -Rules @($cfg.signatureNormalization)
            LOOKBACK_START = ConvertTo-HealthKqlDatetime $now.AddHours(-2); LOOKBACK_END = ConvertTo-HealthKqlDatetime $now; SIGNATURES = "dynamic(['__zed_probe__'])"
        }
        $withParams = {
            param($Signal)
            $v = $base.Clone()
            foreach ($p in @($Signal.params.PSObject.Properties)) {
                $key = 'PARAM_' + (($p.Name -creplace '([a-z0-9])([A-Z])', '$1_$2') -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()
                $v[$key] = if ($p.Value -is [string]) { ConvertTo-HealthKqlString $p.Value } elseif ($p.Value -is [System.Collections.IEnumerable]) { ConvertTo-HealthKqlList @($p.Value | ForEach-Object { [string]$_ }) } elseif ($p.Value -is [bool]) { $(if ($p.Value) { 'true' } else { 'false' }) } else { [string]$p.Value }
            }
            if ($Signal.kind -eq 'counters') { $v['COUNTER_NAMES'] = ConvertTo-HealthKqlList @($Signal.counters.name) }
            $v
        }
        $null = & $run 'exposure' $cfg.exposureQuery $base 'exposure'
        if ($cfg.freshness) { $null = & $run 'freshness' $cfg.freshness.queryFile $base 'freshness' }
        foreach ($s in @($cfg.signals | Where-Object enabled)) {
            $v = & $withParams $s
            $null = & $run $s.id $s.queryFile $v $s.kind
            if ($s.historyQueryFile) { $null = & $run "$($s.id)-history" $s.historyQueryFile $v 'history' }
            if ($s.startFailureQueryFile) { $null = & $run "$($s.id)-start-failures" $s.startFailureQueryFile $v 'startFailures' }
        }
        foreach ($d in @($cfg.rca.drilldowns)) {
            $v = & $withParams ([pscustomobject]@{ params = $(if ($d.params) { $d.params } else { [pscustomobject]@{ requestIds = @('__zed_probe__') } }); kind = 'drilldown' })
            if (-not $v.ContainsKey('PARAM_REQUEST_IDS')) { $v['PARAM_REQUEST_IDS'] = "dynamic(['__zed_probe__'])" }
            $null = & $run "drilldown:$($d.id)" $d.queryFile $v $null
        }
        foreach ($r in $results) {
            if ($r.error) { $issues.Add("Query $($r.name) failed: $($r.error)") }
            elseif ($r.missingColumns.Count) { $issues.Add("Query $($r.name) is missing contract column(s): $($r.missingColumns -join ', ')") }
        }
        if (-not @($results | Where-Object { $_.name -eq 'cohort' -and $_.rows -gt 0 }).Count) { $issues.Add('Cohort query returned no rows') }
    }
}
[pscustomobject]@{ ok = -not $issues.Count; issues = $issues.ToArray(); release = $ReleaseVersion; skillPath = $hc.SkillPath; queries = $results.ToArray() }
