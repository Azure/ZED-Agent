<#
.SYNOPSIS
    Runs one release health check (tripwire / checkpoint / final) for a wave of a release.

.DESCRIPTION
    Service-agnostic engine. Everything service-specific comes from the service's release-health
    skill (service-config.json -> releaseHealth.skillPath -> health-config.json + KQL files).

      1. Cohorts       exact release version per unit (T0 = first telemetry from it), control units
                       still on the previous build, waves (canary / EV2 stage / T0 gaps)
      2. Windows       current (T0+offset .. now-lag) vs previousDay (same units, previous build) and
                       previousWeek; control units over the same windows (difference-in-differences)
      3. Data quality  version purity per window, silent units, ingestion freshness, classification
      4. Signals       outcomes / latency / signatures / counters / series / lifecycle (health-config.json)
      5. Verdict       NO-GO / INCONCLUSIVE / HOLD / GO (HealthLib.ps1 Get-HealthVerdict)
      6. Report        JSON + HTML under .zed-agent/releases/<id>/health/<wave>/ (or -OutDir)

    Manual / backtest examples:
      # Final verdict for the Day2 wave of the current release
      ./Invoke-ReleaseHealthCheck.ps1 -ReleaseId BCM2610_2 -Wave Day2 -Tier final
      # Backtest a past release as it looked at a given time
      ./Invoke-ReleaseHealthCheck.ps1 -ReleaseVersion 3.0.881.0-master -PreviousVersion 3.0.879.1-master `
          -Units ea,wcus -AsOf 2026-09-20T09:00:00Z -Tier final -OutDir ./backtest

.OUTPUTS
    The report object (also written as <tier>-<timestamp>.json/.html unless -NoFiles).
#>
[CmdletBinding()]
param(
    [string]$ReleaseId,
    [string]$ReleaseVersion,
    [string]$PreviousVersion,
    [ValidateSet('tripwire', 'checkpoint', 'final')][string]$Tier = 'final',
    [string]$Wave = 'all',
    [string[]]$Units,
    [Nullable[datetime]]$AsOf,
    [string]$RepoRoot,
    [string]$OutDir,
    [hashtable]$StageMap,
    $Cohorts,
    [string]$ClassificationCommit,
    [hashtable]$UserErrorMap,
    [string[]]$AcceptedIds = @(),
    $Override,
    [scriptblock]$KqlInvoker,
    [string]$Drilldown,
    [hashtable]$DrilldownParams = @{},
    [switch]$NoFiles
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HealthLib.ps1')
. (Join-Path $PSScriptRoot 'HealthKusto.ps1')
. (Join-Path $PSScriptRoot 'HealthConfig.ps1')
. (Join-Path $PSScriptRoot 'HealthState.ps1')
. (Join-Path $PSScriptRoot 'HealthReport.ps1')

$started = Get-Date
if (-not $RepoRoot) { $RepoRoot = Get-HealthRepoRoot }
$asOfUtc = if ($AsOf) { ([datetime]$AsOf).ToUniversalTime() } else { [datetime]::UtcNow }
$svc = Read-HealthServiceConfig -RepoRoot $RepoRoot
$hc = Get-HealthConfig -RepoRoot $RepoRoot -ServiceConfig $svc
$cfg = $hc.Config
$mode = if ($svc.releaseHealth -and $svc.releaseHealth.mode) { [string]$svc.releaseHealth.mode } else { 'shadow' }

$state = $null
if ($ReleaseId) {
    $stateFile = Join-Path $RepoRoot ".zed-agent\releases\$ReleaseId\state.json"
    if (Test-Path -LiteralPath $stateFile) { $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
}
if (-not $ReleaseVersion) {
    if (-not $state) { throw 'Pass -ReleaseVersion, or -ReleaseId of a release whose state.json has buildNumber and branch.' }
    $ri = Get-HealthReleaseInfo -State $state -ReleaseId $ReleaseId
    if (-not $ri.BuildNumber) { throw "state.json of $ReleaseId has no buildNumber yet." }
    $ReleaseVersion = Get-HealthReleaseVersion -BuildNumber $ri.BuildNumber -Branch $ri.Branch -VersionConfig $cfg.version
}
if (-not $ClassificationCommit -and $state -and $state.PSObject.Properties['releaseHealth'] -and $state.releaseHealth -and $state.releaseHealth.errorClassificationCommit) {
    $ClassificationCommit = [string]$state.releaseHealth.errorClassificationCommit
}

# ── Query runner ──────────────────────────────────────────────────────────────
$queryLog = [System.Collections.Generic.List[object]]::new()
$runQuery = {
    param([string]$Name, [string]$File, [hashtable]$Values)
    $text = Expand-HealthQuery -Query $hc.Queries[$File] -Values $Values
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $entry = [ordered]@{ name = $Name; file = $File; rows = 0; seconds = 0; error = $null; adxLink = $null }
    try {
        $rows = if ($KqlInvoker) { @(& $KqlInvoker $Name $text) } else { @(Invoke-HealthKql -Cluster $cfg.dataSource.cluster -Database $cfg.dataSource.database -Query $text -TimeoutMinutes $cfg.dataSource.queryTimeoutMinutes -MaxRows $cfg.dataSource.maxRows) }
        $entry.rows = $rows.Count
        return , $rows
    } catch {
        $entry.error = $_.Exception.Message
        throw
    } finally {
        $entry.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        try { $entry.adxLink = Get-HealthAdxLink -Cluster $cfg.dataSource.cluster -Database $cfg.dataSource.database -Query $text } catch { }
        $queryLog.Add([pscustomobject]$entry)
    }
}

function ConvertTo-HealthKqlLiteral($v) {
    if ($null -eq $v) { return 'dynamic(null)' }
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $v)) }
    if ($v -is [string]) { return ConvertTo-HealthKqlString $v }
    if ($v -is [System.Collections.IEnumerable]) { return ConvertTo-HealthKqlList @($v | ForEach-Object { [string]$_ }) }
    'dynamic(' + ($v | ConvertTo-Json -Compress -Depth 6) + ')'
}

function New-HealthWindowsLiteral([object[]]$Rows) {
    $body = (@($Rows) | ForEach-Object { "{0}, {1}, {2}, {3}, {4}" -f (ConvertTo-HealthKqlString $_.Unit), (ConvertTo-HealthKqlString $_.Cohort), (ConvertTo-HealthKqlString $_.Window), (ConvertTo-HealthKqlDatetime $_.WStart), (ConvertTo-HealthKqlDatetime $_.WEnd) }) -join ",`n"
    "datatable(Unit:string, Cohort:string, Window:string, WStart:datetime, WEnd:datetime)[`n$body`n]"
}

function New-HealthValues([object[]]$WindowRows, $Signal) {
    $win = @($WindowRows)
    $minT = if ($win.Count) { ($win.WStart | Sort-Object | Select-Object -First 1) } else { $asOfUtc.AddHours(-1) }
    $maxT = if ($win.Count) { ($win.WEnd | Sort-Object | Select-Object -Last 1) } else { $asOfUtc }
    $v = @{
        UNITS = ConvertTo-HealthKqlList @($win.Unit | Select-Object -Unique)
        RELEASE_UNITS = ConvertTo-HealthKqlList @($selected.Unit)
        CONTROL_UNITS = ConvertTo-HealthKqlList @($control.Unit)
        WINDOWS = New-HealthWindowsLiteral $win
        MIN_TIME = ConvertTo-HealthKqlDatetime $minT
        MAX_TIME = ConvertTo-HealthKqlDatetime $maxT
        TIME_FILTER = ConvertTo-HealthKqlTimeFilter -Windows $win
        WINDOWS_WIDE = ConvertTo-HealthKqlWindowsWide -Windows $win
        WINDOW_CASE = Get-HealthKqlWindowCase
        T0S = "datatable(Unit:string, T0:datetime)[`n" + ((@($selected) | ForEach-Object { "{0}, {1}" -f (ConvertTo-HealthKqlString $_.Unit), (ConvertTo-HealthKqlDatetime $_.T0) }) -join ",`n") + "`n]"
        RELEASE_VERSION = ConvertTo-HealthKqlString $ReleaseVersion
        PREVIOUS_VERSION = ConvertTo-HealthKqlString $Cohorts.PreviousVersion
        AS_OF = ConvertTo-HealthKqlDatetime $asOfUtc
        SIGNATURE_EXPR = ConvertTo-HealthKqlSignatureExpression -Rules @($cfg.signatureNormalization)
    }
    if ($Signal) {
        foreach ($p in $Signal.params.PSObject.Properties) {
            $key = 'PARAM_' + (($p.Name -creplace '([a-z0-9])([A-Z])', '$1_$2') -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()
            $v[$key] = ConvertTo-HealthKqlLiteral $p.Value
        }
        if ($Signal.kind -eq 'counters') { $v['COUNTER_NAMES'] = ConvertTo-HealthKqlList @($Signal.counters.name) }
    }
    $v
}

# ── 1. Cohorts ────────────────────────────────────────────────────────────────
if (-not $Cohorts) {
    $cohortValues = @{ LOOKBACK_START = ConvertTo-HealthKqlDatetime $asOfUtc.AddDays(-[double]$cfg.timing.cohortLookbackDays); AS_OF = ConvertTo-HealthKqlDatetime $asOfUtc; RELEASE_VERSION = ConvertTo-HealthKqlString $ReleaseVersion }
    $cohortRows = & $runQuery 'cohort' $cfg.cohortQuery $cohortValues
    if (-not $StageMap -and $state -and $cfg.scope.stageLabels -eq 'ev2') {
        $prefixMap = Get-HealthPrefixRegionMap -ServiceConfig $svc -ScriptsDir (Join-Path $PSScriptRoot '..')
        $StageMap = Get-HealthStageMap -State $state -Units @($cohortRows.Unit | Select-Object -Unique) -UnitPrefixRegex $cfg.scope.unitPrefixRegex -PrefixRegionMap $prefixMap
    }
    if (-not $StageMap) { $StageMap = @{} }
    $Cohorts = Get-HealthCohorts -Rows $cohortRows -ReleaseVersion $ReleaseVersion -PreviousVersion $PreviousVersion -Scope $cfg.scope -AsOf $asOfUtc `
        -WaveGapMinutes ([int]$cfg.scope.waveGapMinutes) -StageMap $StageMap -ActiveWithinMinutes ([int]$cfg.scope.activeWithinMinutes)
}
$release = @($Cohorts.Release)
if ($Units) {
    $selected = @($release | Where-Object { $_.Unit -in $Units -or $_.Prefix -in $Units })
    $waveObj = [pscustomobject]@{ Id = 'selected'; Label = 'Selected stamps'; IsCanary = (@($selected | Where-Object IsCanary).Count -eq $selected.Count -and $selected.Count -gt 0) }
} elseif ($Wave -and $Wave -ne 'all') {
    $waveObj = @($Cohorts.Waves | Where-Object { $_.Id -eq $Wave -or $_.Label -eq $Wave }) | Select-Object -Last 1
    if (-not $waveObj) { throw "Wave '$Wave' not found. Waves: $((@($Cohorts.Waves) | ForEach-Object { "$($_.Id) ($($_.Label))" }) -join ', ')" }
    $selected = @($release | Where-Object { $_.Unit -in $waveObj.Units })
} else {
    $selected = $release
    $waveObj = [pscustomobject]@{ Id = 'all'; Label = 'All deployed stamps'; IsCanary = $false }
}
if (-not $selected.Count) { throw "No stamp runs $ReleaseVersion as of $($asOfUtc.ToString('o')) for the requested scope." }
$control = if ($cfg.comparison.controlEnabled) { @($Cohorts.Control) } else { @() }
$t0First = ($selected | Sort-Object T0 | Select-Object -First 1).T0
$t0Last = ($selected | Sort-Object T0 | Select-Object -Last 1).T0
$ageHours = ($asOfUtc - $t0Last).TotalHours
$cycleMin = [double]$cfg.timing.workloadCycleHours * 60
$cycles = [math]::Max(0, [math]::Floor((($asOfUtc - $t0Last).TotalMinutes - [double]$cfg.timing.ingestionLagMinutes) / $cycleMin))
$minBake = if ($waveObj.IsCanary) { [double]$cfg.timing.minBakeHours.canary } else { [double]$cfg.timing.minBakeHours.default }
$bakeComplete = $ageHours -ge $minBake -and $cycles -ge [int]$cfg.timing.minCyclesForVerdict

# ── 2. Windows ────────────────────────────────────────────────────────────────
$signals = @($cfg.signals | Where-Object { $_.enabled -and (@($_.tiers) -contains $Tier) })
$neededWindows = @(@('current', [string]$cfg.comparison.baseWindow, [string]$cfg.comparison.confirmWindow) + @($signals | ForEach-Object { @($_.windows) })) | Select-Object -Unique
$windows = @(Get-HealthWindows -ReleaseUnits $selected -ControlUnits $control -AsOf $asOfUtc -Timing $cfg.timing -Windows $neededWindows)

# RCA drill-down mode (used by the agent): same scope/windows/placeholders, free-form rows back.
if ($Drilldown) {
    $d = @($cfg.rca.drilldowns | Where-Object id -eq $Drilldown) | Select-Object -First 1
    if (-not $d) { throw "Drill-down '$Drilldown' is not defined in health-config.json → rca.drilldowns ($(@($cfg.rca.drilldowns.id) -join ', '))." }
    $p = [pscustomobject]@{}
    foreach ($src in @($d.params, [pscustomobject]$DrilldownParams)) { if ($src) { foreach ($pp in $src.PSObject.Properties) { $p | Add-Member -NotePropertyName $pp.Name -NotePropertyValue $pp.Value -Force } } }
    $rows = & $runQuery "drilldown:$Drilldown" $d.queryFile (New-HealthValues $windows ([pscustomobject]@{ params = $p; kind = 'drilldown' }))
    return [pscustomobject]@{ drilldown = $Drilldown; description = $d.description; rows = @($rows | Select-Object -First ([int]$cfg.rca.maxRows)); query = $queryLog[0] }
}

$dqIssues = [System.Collections.Generic.List[string]]::new()
$dqNotes = [System.Collections.Generic.List[string]]::new()
$findings = [System.Collections.Generic.List[object]]::new()
$signalResults = [System.Collections.Generic.List[object]]::new()
$freshness = @()
$classification = $null
$exposure = @{}

if (-not @($windows | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq 'current' }).Count) {
    $dqIssues.Add("Not enough post-deployment data yet (current window starts $($cfg.timing.windowStartOffsetMinutes) min after T0 and ends $($cfg.timing.ingestionLagMinutes) min before now)")
} else {
    # ── 3. Exposure, purity, silent units ──────────────────────────────────────
    $purity = [double]$cfg.comparison.controlPurityMin
    try {
        $expRows = & $runQuery 'exposure' $cfg.exposureQuery (New-HealthValues $windows $null)
        $byKey = @{}; foreach ($r in $expRows) { $k = "$($r.Unit)|$($r.Window)"; if (-not $byKey[$k]) { $byKey[$k] = [System.Collections.Generic.List[object]]::new() }; $byKey[$k].Add($r) }
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($w in $windows) {
            $rs = @($byKey["$($w.Unit)|$($w.Window)"])
            $total = Get-HealthSum $rs 'Ops'
            $rel = Get-HealthSum @($rs | Where-Object Version -eq $ReleaseVersion) 'Ops'
            $prev = Get-HealthSum @($rs | Where-Object Version -eq $Cohorts.PreviousVersion) 'Ops'
            $ok = $true; $why = $null
            if ($total -le 0) {
                $ok = $false
                if ($w.Cohort -eq 'release' -and $w.Window -eq 'current') {
                    $findings.Add((New-HealthFinding -Severity Sev1 -Area 'Stability' -SignalId 'telemetry-silence' -Key "silent|$($w.Unit)" -Units @($w.Unit) -Title "No telemetry from $($w.Unit) on the new build" -Detail "No operations between $($w.WStart.ToString('u')) and $($w.WEnd.ToString('u'))" -QueryName 'exposure'))
                } else { $why = 'no operations' }
            } elseif ($w.Cohort -eq 'release' -and $w.Window -eq 'current' -and $rel / $total -lt $purity) { $ok = $false; $why = ('only {0:p1} on {1}' -f ($rel / $total), $ReleaseVersion) }
            elseif ($w.Cohort -eq 'release' -and $w.Window -ne 'current' -and $rel / $total -gt (1 - $purity)) { $ok = $false; $why = ('{0:p1} already on {1}' -f ($rel / $total), $ReleaseVersion) }
            elseif ($w.Cohort -eq 'control' -and $prev / $total -lt $purity) { $ok = $false; $why = ('only {0:p1} on {1}' -f ($prev / $total), $Cohorts.PreviousVersion) }
            if ($ok) {
                $kept.Add(($w | Add-Member -NotePropertyName Ops -NotePropertyValue $total -Force -PassThru))
            } elseif ($why) { $dqNotes.Add("Excluded $($w.Cohort) window $($w.Unit) / $($w.Window): $why") }
        }
        # Paired comparison: a unit takes part only with both its current and its baseline window,
        # otherwise volumes and rates would compare different sets of units.
        $baseW = [string]$cfg.comparison.baseWindow
        $paired = @($kept | Group-Object Unit | Where-Object { @($_.Group.Window) -contains 'current' -and @($_.Group.Window) -contains $baseW } | ForEach-Object Name)
        foreach ($u in @($kept | Where-Object { $_.Unit -notin $paired } | Select-Object -ExpandProperty Unit -Unique)) {
            $dqNotes.Add("Left $u out of the comparisons: it has no usable 'current' or '$baseW' window")
        }
        $windows = @($kept | Where-Object { $_.Unit -in $paired })
        foreach ($w in $windows) { $k2 = "$($w.Cohort)|$($w.Window)"; $exposure[$k2] = [double]$exposure[$k2] + [double]$w.Ops }
    } catch { $dqIssues.Add("Exposure query failed: $($_.Exception.Message)") }

    $releaseCurrent = @($windows | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq 'current' })
    if (-not $releaseCurrent.Count) { $dqIssues.Add('No release stamp has a usable current window (version purity / telemetry)') }
    foreach ($bw in @([string]$cfg.comparison.baseWindow)) {
        if (-not @($windows | Where-Object { $_.Cohort -eq 'release' -and $_.Window -eq $bw }).Count) { $dqIssues.Add("No usable '$bw' baseline window for the release stamps") }
    }
    if ($control.Count -and -not @($windows | Where-Object { $_.Cohort -eq 'control' }).Count) { $dqNotes.Add('No control window passed the version-purity check; comparisons use the release stamps only') }

    # ── Freshness ──────────────────────────────────────────────────────────────
    if ($cfg.freshness) {
        try {
            $freshness = & $runQuery 'freshness' $cfg.freshness.queryFile (New-HealthValues $windows $null)
            foreach ($f in $freshness) { if ([double]$f.LagMinutes -gt [double]$cfg.freshness.maxLagMinutes -and -not $AsOf) { $dqIssues.Add("$($f.Source) ingestion lag $($f.LagMinutes) min (max $($cfg.freshness.maxLagMinutes))") } }
        } catch { $dqIssues.Add("Freshness query failed: $($_.Exception.Message)") }
    }

    # ── Error classification ───────────────────────────────────────────────────
    if ($UserErrorMap) { $classification = @{ Map = $UserErrorMap; Commit = 'test'; Source = 'injected'; Count = $UserErrorMap.Count } }
    else {
        try { $classification = Get-HealthErrorClassification -Config $cfg -RepoRoot $RepoRoot -PinnedCommit $ClassificationCommit }
        catch { $dqIssues.Add("Error classification unavailable: $($_.Exception.Message)"); $classification = @{ Map = @{}; Commit = $null; Source = 'unavailable'; Count = 0 } }
    }

    # ── 4. Signals ─────────────────────────────────────────────────────────────
    $unitCohort = @{}; foreach ($w in $windows) { $unitCohort[[string]$w.Unit] = $w.Cohort }
    $base = [string]$cfg.comparison.baseWindow; $confirm = [string]$cfg.comparison.confirmWindow
    foreach ($sig in $signals) {
        $sigWindows = @($windows | Where-Object { $_.Window -in @($sig.windows) -and ($sig.includeControl -or $_.Cohort -eq 'release') })
        if ($sig.PSObject.Properties['controlUnits'] -and $sig.controlUnits) {
            $keepCtl = @($sigWindows | Where-Object { $_.Cohort -eq 'control' -and $_.Window -eq 'current' } | Sort-Object { [double]$_.Ops } -Descending | Select-Object -First ([int]$sig.controlUnits) | ForEach-Object Unit)
            $sigWindows = @($sigWindows | Where-Object { $_.Cohort -eq 'release' -or $_.Unit -in $keepCtl })
        }
        $sigExposure = @{}; foreach ($w in $sigWindows) { $k2 = "$($w.Cohort)|$($w.Window)"; $sigExposure[$k2] = [double]$sigExposure[$k2] + [double]$w.Ops }
        $values = New-HealthValues $sigWindows $sig
        try {
            $rows = & $runQuery $sig.id $sig.queryFile $values
            $res = switch ($sig.kind) {
                'outcomes'   { Measure-HealthOutcomes -Rows $rows -Signal $sig -UnitCohort $unitCohort -UserErrorMap $classification.Map -Classification $cfg.errorClassification -Comparison $cfg.comparison -BaseWindow $base -ConfirmWindow $confirm }
                'latency'    { Measure-HealthLatency -Rows $rows -Signal $sig -Comparison $cfg.comparison -BaseWindow $base }
                'counters'   { Measure-HealthCounters -Rows $rows -Signal $sig -UnitCohort $unitCohort -Comparison $cfg.comparison -BaseWindow $base }
                'series'     { Measure-HealthSeries -Rows $rows -Signal $sig -UnitCohort $unitCohort }
                'signatures' {
                    $r = Measure-HealthSignatures -Rows $rows -Signal $sig -Comparison $cfg.comparison -Exposure $sigExposure -BaseWindow $base
                    if (@($r.candidates).Count) {
                        $lookback = if ($sig.thresholds.lookbackDays) { [double]$sig.thresholds.lookbackDays } else { 14 }
                        $hv = $values.Clone()
                        $hv['SIGNATURES'] = ConvertTo-HealthKqlList @($r.candidates.signature)
                        $hv['LOOKBACK_START'] = ConvertTo-HealthKqlDatetime $asOfUtc.AddDays(-$lookback)
                        $hv['LOOKBACK_END'] = ConvertTo-HealthKqlDatetime $asOfUtc
                        $hist = & $runQuery "$($sig.id)-history" $sig.historyQueryFile $hv
                        $r = Resolve-HealthNewSignatures -Result $r -HistoryRows $hist -Signal $sig
                    }
                    $r
                }
                'lifecycle' {
                    $starts = if ($sig.startFailureQueryFile) { & $runQuery "$($sig.id)-start-failures" $sig.startFailureQueryFile $values } else { @() }
                    Measure-HealthLifecycle -Events $rows -StartFailures $starts -ReleaseUnits $selected -Signal $sig -ReleaseVersion $ReleaseVersion
                }
            }
            foreach ($f in @($res.findings)) { $findings.Add($f) }
            $signalResults.Add([pscustomobject]@{ id = $sig.id; title = $sig.title; area = $sig.area; kind = $sig.kind; status = $res.status; summary = $res.summary
                topCodes = $res.topCodes; preExisting = $res.preExistingCandidates; rcaHints = $sig.rcaHints })
        } catch {
            $dqIssues.Add("Signal '$($sig.id)' failed: $($_.Exception.Message)")
            $signalResults.Add([pscustomobject]@{ id = $sig.id; title = $sig.title; area = $sig.area; kind = $sig.kind; status = 'error'; summary = $null; error = $_.Exception.Message })
        }
    }
}

# ── 5. Suppressions, acceptance, verdict ─────────────────────────────────────
foreach ($f in $findings) {
    $s = Test-HealthSuppressed -Finding $f -Suppressions @($cfg.suppressions) -AsOf $asOfUtc
    if ($s) { $f.suppressed = $s.reason }
    $f | Add-Member -NotePropertyName accepted -NotePropertyValue ($f.id -in $AcceptedIds) -Force
}
$verdict = Get-HealthVerdict -Findings $findings.ToArray() -DataQualityIssues $dqIssues.ToArray() -BakeComplete $bakeComplete -AcceptedIds $AcceptedIds -Override $Override
if ($Tier -eq 'tripwire' -and $verdict.verdict -in 'GO', 'HOLD') { $verdict.verdict = 'INCONCLUSIVE'; $verdict.reasons = @('Tripwire checks only look for serious problems; the verdict comes at the checkpoint/final review') + @($verdict.reasons) }

$sevOrder = @{ Sev1 = 0; Inconclusive = 1; Investigate = 2; Watch = 3 }
$report = [pscustomobject][ordered]@{
    schemaVersion   = 1
    service         = $cfg.service
    releaseId       = $ReleaseId
    releaseVersion  = $ReleaseVersion
    previousVersion = $Cohorts.PreviousVersion
    tier            = $Tier
    asOf            = $asOfUtc.ToString('o')
    generatedAt     = [datetime]::UtcNow.ToString('o')
    durationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    wave            = [pscustomobject]@{ id = $waveObj.Id; label = $waveObj.Label; isCanary = [bool]$waveObj.IsCanary; units = @($selected.Unit); t0First = $t0First.ToString('o'); t0Last = $t0Last.ToString('o')
                                         ageHours = [math]::Round($ageHours, 2); cycles = $cycles; minBakeHours = $minBake; bakeComplete = $bakeComplete
                                         stamps = @($selected | ForEach-Object { [pscustomobject]@{ unit = $_.Unit; t0 = $_.T0.ToString('o'); stage = $_.Stage; previousVersion = $_.PreviousVersion } }) }
    control         = [pscustomobject]@{ version = $Cohorts.PreviousVersion; units = @($control.Unit) }
    windows         = @($windows | Group-Object Cohort, Window | ForEach-Object { [pscustomobject]@{ cohort = $_.Group[0].Cohort; window = $_.Group[0].Window; units = $_.Count
                        start = ($_.Group.WStart | Sort-Object | Select-Object -First 1).ToString('o'); end = ($_.Group.WEnd | Sort-Object | Select-Object -Last 1).ToString('o'); ops = $exposure["$($_.Group[0].Cohort)|$($_.Group[0].Window)"] } })
    dataQuality     = [pscustomobject]@{ issues = $dqIssues.ToArray(); notes = $dqNotes.ToArray(); freshness = @($freshness) }
    classification  = if ($classification) { [pscustomobject]@{ source = $classification.Source; commit = $classification.Commit; count = $classification.Count } } else { $null }
    signals         = $signalResults.ToArray()
    findings        = @($findings | Sort-Object { $sevOrder[$_.severity] }, area, title)
    verdict         = $verdict
    queries         = $queryLog.ToArray()
    config          = [pscustomobject]@{ skillPath = $hc.SkillPath; dashboardUrl = $cfg.dashboardUrl; mode = $mode; cluster = $cfg.dataSource.cluster; database = $cfg.dataSource.database }
    agentNotes      = $null
}

if (-not $NoFiles) {
    if (-not $OutDir) {
        $OutDir = if ($ReleaseId) { Join-Path $RepoRoot ".zed-agent\releases\$ReleaseId\health\$($waveObj.Id)" } else { Join-Path $RepoRoot ".zed-agent\health-runs\$($asOfUtc.ToString('yyyyMMddTHHmmZ'))" }
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $stem = Join-Path $OutDir ("{0}-{1}" -f $Tier, [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    $kind = if ($Tier -eq 'final') { 'verdict' } elseif (@($report.findings | Where-Object { $_.severity -eq 'Sev1' -and -not $_.suppressed }).Count) { 'early-warning' } else { 'interim' }
    $report | Add-Member -NotePropertyName files -NotePropertyValue ([pscustomobject]@{ json = "$stem.json"; html = "$stem.html" }) -Force
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$stem.json" -Encoding UTF8
    ConvertTo-HealthReportHtml -Report $report -Kind $kind -ReleaseName $ReleaseId | Set-Content -LiteralPath "$stem.html" -Encoding UTF8
}
$report
