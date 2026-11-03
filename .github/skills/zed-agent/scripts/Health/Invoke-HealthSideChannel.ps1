<#
.SYNOPSIS
    Release health side-channel for Release-Watcher.ps1 (and manual runs).

.DESCRIPTION
    -Action Start    Fast; called by the watcher every loop/sleep tick. When releaseHealth.enabled,
                     the release build is known and a run is due (timing.planIntervalMinutes), starts
                     `-Action Run` as a background pwsh process (never blocks the watcher).
    -Action Run      Background run: computes cohorts/waves from telemetry, decides per wave which
                     check is due and runs it (Invoke-ReleaseHealthCheck.ps1):
                       tripwire    every tripwireIntervalMinutes after T0 + firstCheckAfterT0Minutes
                       checkpoint  after each completed workload cycle (workloadCycleHours)
                       final       once the minimum bake is reached AND (EV2 reports the stage complete
                                   OR finalVerdictAfterHours elapsed); INCONCLUSIVE finals retry next cycle
                     then queues notifications in state.releaseHealth.notifications:
                       early-warning  new Sev1 finding (release-health-early-warning)
                       interim        new Investigate findings at a checkpoint (owner-only)
                       verdict        final GO / HOLD / NO-GO / INCONCLUSIVE (release-health-<verdict>)
    -Action Pending  Notifications waiting for the agent (status pending / agent-failed with attempts < 3).
    -Action Mark     Records the agent's result for -NotificationId (-Success / failure). Called by the watcher.
    -Action Annotate Agent RCA for -NotificationId (-RcaFile): adds finding.rca, agentNotes and an optional
                     escalation (GO -> HOLD/NO-GO, HOLD/INCONCLUSIVE -> NO-GO; never a downgrade), re-renders
                     the HTML and updates the notification (verdict, eventKey, subject). Returns the notification.
    -Action Accept   Owner accepts a finding (-FindingId -Reason -By): it no longer counts from the next run.
    -Action Override Owner decision for a wave (-WaveId -Verdict -Reason -By); applied by every later check.
    -Action Status   Waves, latest reports, pending notifications, accepted findings and overrides.

    State: state.releaseHealth (see reference/release-health.md). Audit: health-* events in audit.jsonl.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Run', 'Pending', 'Mark', 'Annotate', 'Accept', 'Override', 'Status')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$RepoRoot,
    [string]$NotificationId,
    [switch]$Success,
    # Annotate: JSON file { agentNotes, findings: { <findingId>: { classification, confidence, summary, evidence[], suspects[], recommendation } }, escalate: { verdict, reason } }
    [string]$RcaFile,
    # Accept / Override
    [string]$FindingId,
    [string]$WaveId,
    [ValidateSet('GO', 'HOLD', 'NO-GO', '')][string]$Verdict = '',
    [string]$Reason,
    [string]$By,
    [Nullable[datetime]]$AsOf,
    [switch]$Force,
    # Test seam: replaces Kusto (passed through to Invoke-ReleaseHealthCheck.ps1).
    [scriptblock]$KqlInvoker
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HealthLib.ps1')
. (Join-Path $PSScriptRoot 'HealthKusto.ps1')
. (Join-Path $PSScriptRoot 'HealthConfig.ps1')
. (Join-Path $PSScriptRoot 'HealthState.ps1')
. (Join-Path $PSScriptRoot 'HealthReport.ps1')
. (Join-Path $PSScriptRoot '..\Invoke-WithStateLock.ps1')

if (-not $RepoRoot) { $RepoRoot = Get-HealthRepoRoot }
$relDir = Join-Path $RepoRoot ".zed-agent\releases\$ReleaseId"
$stateFile = Join-Path $relDir 'state.json'
$stateLock = Join-Path $relDir 'state.json.lock'
$auditFile = Join-Path $relDir 'audit.jsonl'
$now = if ($AsOf) { ([datetime]$AsOf).ToUniversalTime() } else { [datetime]::UtcNow }

function Write-HealthAudit([string]$Event, [hashtable]$Data = @{}) {
    $o = [ordered]@{ ts = (Get-Date -Format 'o'); event = $Event }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    try { [pscustomobject]$o | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $auditFile -Encoding UTF8 } catch { }
}

function Read-State { Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-OrAdd($Object, [string]$Name, $Default) {
    if (-not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Default -Force }
    $Object.$Name
}

# Applies $Mutate to state.releaseHealth under the state lock and writes state.json back.
function Update-HealthState([scriptblock]$Mutate) {
    # Plain scriptblock (no closure): dynamic scoping gives it $Mutate and the caller's variables.
    Invoke-WithStateLock -LockFile $stateLock -TimeoutSeconds 60 -Action {
        $st = Read-State
        $rh = Get-OrAdd $st 'releaseHealth' ([pscustomobject]@{})
        foreach ($n in 'waves', 'notifications', 'overrides') { $null = Get-OrAdd $rh $n ([pscustomobject]@{}) }
        $null = Get-OrAdd $rh 'accepted' @()
        & $Mutate $rh $st
        $st | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $stateFile -Encoding UTF8 -NoNewline
    }
}

$svc = Read-HealthServiceConfig -RepoRoot $RepoRoot
$enabled = $svc.PSObject.Properties['releaseHealth'] -and $svc.releaseHealth -and $svc.releaseHealth.enabled -eq $true
if (-not (Test-Path -LiteralPath $stateFile)) { return [pscustomobject]@{ action = $Action; skipped = 'no state.json' } }

switch ($Action) {
    'Pending' {
        $st = Read-State
        if (-not $st.PSObject.Properties['releaseHealth'] -or -not $st.releaseHealth -or -not $st.releaseHealth.notifications) { return @() }
        return @($st.releaseHealth.notifications.PSObject.Properties | ForEach-Object Value |
            Where-Object { $_.status -eq 'pending' -or ($_.status -eq 'agent-failed' -and [int]$_.attempts -lt 3) } | Sort-Object createdAt)
    }
    'Mark' {
        if (-not $NotificationId) { throw '-NotificationId is required for -Action Mark' }
        $ok = [bool]$Success
        Update-HealthState {
            param($rh)
            $n = $rh.notifications.PSObject.Properties[$NotificationId].Value
            if (-not $n) { return }
            $n.attempts = [int]$n.attempts + 1
            $n.status = if ($ok) { 'sent' } else { 'agent-failed' }
            $n | Add-Member -NotePropertyName lastAttemptAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
        }
        Write-HealthAudit 'health-notification' @{ id = $NotificationId; success = $ok }
        return
    }
    'Annotate' {
        if (-not $NotificationId -or -not $RcaFile) { throw '-NotificationId and -RcaFile are required for -Action Annotate' }
        $st = Read-State
        $n = $st.releaseHealth.notifications.PSObject.Properties[$NotificationId].Value
        if (-not $n) { throw "Notification $NotificationId not found" }
        $rca = Get-Content -LiteralPath $RcaFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $report = Get-Content -LiteralPath $n.json -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rca.findings) {
            foreach ($p in $rca.findings.PSObject.Properties) {
                $f = @($report.findings | Where-Object id -eq $p.Name) | Select-Object -First 1
                if (-not $f) { throw "Finding $($p.Name) is not in $($n.json)" }
                $f | Add-Member -NotePropertyName rca -NotePropertyValue $p.Value -Force
            }
        }
        if ($rca.agentNotes) { $report | Add-Member -NotePropertyName agentNotes -NotePropertyValue ([string]$rca.agentNotes) -Force }
        $rank = @{ 'GO' = 0; 'HOLD' = 1; 'INCONCLUSIVE' = 1; 'NO-GO' = 2 }
        $old = [string]$report.verdict.verdict
        if ($rca.escalate -and $rca.escalate.verdict) {
            $new = ([string]$rca.escalate.verdict).ToUpperInvariant()
            if (-not $rank.ContainsKey($new) -or $new -eq 'INCONCLUSIVE') { throw "Escalation verdict must be HOLD or NO-GO (got '$new')" }
            if ($rank[$new] -le $rank[$old]) { throw "The agent may only escalate a verdict ($old -> $new is not an escalation). Owners lower verdicts with 'health override'." }
            if (-not $rca.escalate.reason) { throw 'escalate.reason is required' }
            $report.verdict.verdict = $new
            $report.verdict.reasons = @("Escalated by the agent after RCA: $($rca.escalate.reason)") + @($report.verdict.reasons)
            $report.verdict | Add-Member -NotePropertyName escalatedFrom -NotePropertyValue $old -Force
        }
        $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $n.json -Encoding UTF8
        ConvertTo-HealthReportHtml -Report $report -Kind $n.kind -ReleaseName $ReleaseId | Set-Content -LiteralPath $n.html -Encoding UTF8
        $subject = Get-HealthSubject -Report $report -Kind $n.kind -ReleaseName $ReleaseId
        $verdictNow = [string]$report.verdict.verdict
        Update-HealthState {
            param($rh)
            $nn = $rh.notifications.$NotificationId
            $nn | Add-Member -NotePropertyName subject -NotePropertyValue $subject -Force
            $nn | Add-Member -NotePropertyName verdict -NotePropertyValue $verdictNow -Force
            $nn | Add-Member -NotePropertyName annotatedAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            if ($nn.kind -eq 'verdict') {
                $nn.eventKey = 'release-health-' + $verdictNow.ToLowerInvariant()
                $rw = $rh.waves.PSObject.Properties[$nn.waveId].Value
                if ($rw) { $rw.finalVerdict = $verdictNow }
            }
        }
        Write-HealthAudit 'health-annotated' @{ id = $NotificationId; verdict = $verdictNow; escalatedFrom = $(if ($verdictNow -ne $old) { $old } else { $null }); rcaFindings = @($rca.findings.PSObject.Properties.Name) }
        return (Read-State).releaseHealth.notifications.$NotificationId
    }
    'Accept' {
        if (-not $FindingId -or -not $Reason) { throw '-FindingId and -Reason are required for -Action Accept' }
        $entry = [pscustomobject]@{ findingId = $FindingId; reason = $Reason; by = $By; at = [datetime]::UtcNow.ToString('o') }
        Update-HealthState { param($rh) $rh.accepted = @(@($rh.accepted | Where-Object { $_ -and $_.findingId -ne $FindingId }) + $entry) }
        Write-HealthAudit 'health-accepted' @{ findingId = $FindingId; reason = $Reason; by = $By }
        return $entry
    }
    'Override' {
        if (-not $WaveId -or -not $Verdict -or -not $Reason) { throw '-WaveId, -Verdict and -Reason are required for -Action Override' }
        $entry = [pscustomobject]@{ verdict = $Verdict; reason = $Reason; decidedBy = $By; at = [datetime]::UtcNow.ToString('o') }
        Update-HealthState {
            param($rh)
            if (-not $rh.waves.PSObject.Properties[$WaveId]) { throw "Wave $WaveId not found (waves: $(@($rh.waves.PSObject.Properties.Name) -join ', '))" }
            $rh.overrides | Add-Member -NotePropertyName $WaveId -NotePropertyValue $entry -Force
            $rw = $rh.waves.$WaveId
            if ($rw.finalAt -or $rw.finalVerdict) { $rw.finalVerdict = $Verdict; if (-not $rw.finalAt) { $rw.finalAt = $entry.at } }
        }
        Write-HealthAudit 'health-override' @{ waveId = $WaveId; verdict = $Verdict; reason = $Reason; by = $By }
        return $entry
    }
    'Status' {
        $st = Read-State
        $rh = if ($st.PSObject.Properties['releaseHealth']) { $st.releaseHealth } else { $null }
        if (-not $rh) { return [pscustomobject]@{ enabled = $enabled; waves = @(); pending = @() } }
        return [pscustomobject]@{
            enabled = $enabled; mode = $svc.releaseHealth.mode; releaseVersion = $rh.releaseVersion; previousVersion = $rh.previousVersion
            lastRunAt = $rh.lastRunAt; lastRunSummary = $rh.lastRunSummary; running = $rh.running
            waves = @(if ($rh.waves) { $rh.waves.PSObject.Properties | ForEach-Object { $w = $_.Value; $last = @($w.reports) | Select-Object -Last 1
                [pscustomobject]@{ id = $_.Name; label = $w.label; units = @($w.units).Count; t0Last = $w.t0Last; finalVerdict = $w.finalVerdict; lastTier = $last.tier; lastVerdict = $last.verdict; lastReport = $last.html; override = $(if ($rh.overrides) { $rh.overrides.($_.Name) }) } } })
            pending = @(if ($rh.notifications) { $rh.notifications.PSObject.Properties.Value | Where-Object { $_.status -ne 'sent' } })
            accepted = @($rh.accepted)
        }
    }
    'Start' {
        if (-not $enabled) { return [pscustomobject]@{ started = $false; reason = 'releaseHealth disabled' } }
        $st = Read-State
        if (-not $st.buildNumber) { return [pscustomobject]@{ started = $false; reason = 'release build not known yet' } }
        if ($st.status -in 'completed', 'stopped', 'aborted') { return [pscustomobject]@{ started = $false; reason = "release $($st.status)" } }
        if ([int]$st.currentStep -lt 5 -and -not $Force) { return [pscustomobject]@{ started = $false; reason = 'canary not deployed yet' } }
        $hc = Get-HealthConfig -RepoRoot $RepoRoot -ServiceConfig $svc -SkipSchema
        $rh = if ($st.PSObject.Properties['releaseHealth']) { $st.releaseHealth } else { $null }
        $maxRun = if ($svc.releaseHealth.maxRunMinutes) { [int]$svc.releaseHealth.maxRunMinutes } else { 40 }
        if ($rh -and $rh.running -and $rh.running.pid) {
            $alive = Get-Process -Id ([int]$rh.running.pid) -ErrorAction SilentlyContinue
            if ($alive -and ($now - [datetime]$rh.running.startedAt).TotalMinutes -lt $maxRun) { return [pscustomobject]@{ started = $false; reason = 'run in progress' } }
            if ($alive) { try { Stop-Process -Id ([int]$rh.running.pid) -Force } catch { }; Write-HealthAudit 'health-run-killed' @{ pid = $rh.running.pid } }
        }
        $interval = [double]$hc.Config.timing.planIntervalMinutes
        if (-not $Force -and $rh -and $rh.lastRunAt -and ($now - [datetime]$rh.lastRunAt).TotalMinutes -lt $interval) { return [pscustomobject]@{ started = $false; reason = 'not due' } }
        $pwsh = (Get-Process -Id $PID).Path
        $logDir = Join-Path $relDir 'health'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $p = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Action', 'Run', '-ReleaseId', $ReleaseId, '-RepoRoot', $RepoRoot) `
            -WorkingDirectory $RepoRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logDir 'last-run.out.log') -RedirectStandardError (Join-Path $logDir 'last-run.err.log')
        $startedAt = [datetime]::UtcNow.ToString('o')
        Update-HealthState { param($rh2) $rh2 | Add-Member -NotePropertyName running -NotePropertyValue ([pscustomobject]@{ pid = $p.Id; startedAt = $startedAt }) -Force; $rh2 | Add-Member -NotePropertyName lastRunAt -NotePropertyValue $startedAt -Force }
        Write-HealthAudit 'health-run-started' @{ pid = $p.Id }
        return [pscustomobject]@{ started = $true; pid = $p.Id }
    }
    'Run' {
        $summary = [System.Collections.Generic.List[string]]::new()
        try {
            if (-not $enabled -and -not $Force) { return }
            $st = Read-State
            $hc = Get-HealthConfig -RepoRoot $RepoRoot -ServiceConfig $svc
            $cfg = $hc.Config
            $ri = Get-HealthReleaseInfo -State $st -ReleaseId $ReleaseId
            $releaseVersion = Get-HealthReleaseVersion -BuildNumber $ri.BuildNumber -Branch $ri.Branch -VersionConfig $cfg.version
            $rhOld = if ($st.PSObject.Properties['releaseHealth'] -and $st.releaseHealth) { $st.releaseHealth } else { [pscustomobject]@{} }

            # Pin the error classification for the whole release.
            $commit = [string]$rhOld.errorClassificationCommit
            if (-not $commit) {
                try { $commit = (Get-HealthErrorClassification -Config $cfg -RepoRoot $RepoRoot).Commit } catch { $summary.Add("classification: $($_.Exception.Message)") }
            }

            # Cohorts + stage labels.
            $cohortText = Expand-HealthQuery -Query $hc.Queries[$cfg.cohortQuery] -Values @{ LOOKBACK_START = ConvertTo-HealthKqlDatetime $now.AddDays(-[double]$cfg.timing.cohortLookbackDays); AS_OF = ConvertTo-HealthKqlDatetime $now; RELEASE_VERSION = ConvertTo-HealthKqlString $releaseVersion }
            $cohortRows = if ($KqlInvoker) { @(& $KqlInvoker 'cohort' $cohortText) } else { Invoke-HealthKql -Cluster $cfg.dataSource.cluster -Database $cfg.dataSource.database -Query $cohortText -TimeoutMinutes $cfg.dataSource.queryTimeoutMinutes }
            $stageMap = @{}
            if ($cfg.scope.stageLabels -eq 'ev2') {
                $prefixMap = Get-HealthPrefixRegionMap -ServiceConfig $svc -ScriptsDir (Join-Path $PSScriptRoot '..')
                $stageMap = Get-HealthStageMap -State $st -Units @($cohortRows.Unit | Select-Object -Unique) -UnitPrefixRegex $cfg.scope.unitPrefixRegex -PrefixRegionMap $prefixMap
            }
            $cohorts = Get-HealthCohorts -Rows $cohortRows -ReleaseVersion $releaseVersion -Scope $cfg.scope -AsOf $now -WaveGapMinutes ([int]$cfg.scope.waveGapMinutes) -StageMap $stageMap -ActiveWithinMinutes ([int]$cfg.scope.activeWithinMinutes)
            if (-not @($cohorts.Waves).Count) { $summary.Add("no stamp runs $releaseVersion yet") }

            $t = $cfg.timing
            $accepted = @($rhOld.accepted | Where-Object { $_ } | ForEach-Object findingId)
            $heavyBudget = 1
            $results = [System.Collections.Generic.List[object]]::new()
            foreach ($w in $cohorts.Waves) {
                $rec = if ($rhOld.waves -and $rhOld.waves.PSObject.Properties[$w.Id]) { $rhOld.waves.($w.Id) } else { $null }
                if ($rec -and $rec.finalAt -and $rec.finalVerdict -ne 'INCONCLUSIVE') { continue }
                $ageMin = ($now - $w.T0Last).TotalMinutes
                $cycles = [math]::Max(0, [math]::Floor(($ageMin - [double]$t.ingestionLagMinutes) / ([double]$t.workloadCycleHours * 60)))
                $minBake = if ($w.IsCanary) { [double]$t.minBakeHours.canary } else { [double]$t.minBakeHours.default }
                $finalAfter = if ($w.IsCanary) { [double]$t.finalVerdictAfterHours.canary } else { [double]$t.finalVerdictAfterHours.default }
                $lastCycle = if ($rec -and $null -ne $rec.lastCheckpointCycle) { [int]$rec.lastCheckpointCycle } else { 0 }
                $lastTrip = if ($rec -and $rec.lastTripwireAt) { [datetime]$rec.lastTripwireAt } else { [datetime]::MinValue }
                $stageDone = Test-HealthStageComplete -State $st -Label $w.Label
                $tier = $null
                if ($ageMin / 60 -ge $minBake -and $cycles -ge [int]$t.minCyclesForVerdict -and ($stageDone -or $ageMin / 60 -ge $finalAfter) -and $cycles -gt $(if ($rec -and $rec.finalVerdict -eq 'INCONCLUSIVE') { $lastCycle } else { -1 })) { $tier = 'final' }
                elseif ($cycles -ge 1 -and $cycles -gt $lastCycle) { $tier = 'checkpoint' }
                elseif ($ageMin -ge [double]$t.firstCheckAfterT0Minutes -and ($now - $lastTrip).TotalMinutes -ge [double]$t.tripwireIntervalMinutes) { $tier = 'tripwire' }
                if (-not $tier) { continue }
                if ($tier -ne 'tripwire') { if ($heavyBudget -le 0) { $tier = 'tripwire'; if (($now - $lastTrip).TotalMinutes -lt [double]$t.tripwireIntervalMinutes) { continue } } else { $heavyBudget-- } }
                $override = if ($rhOld.overrides -and $rhOld.overrides.PSObject.Properties[$w.Id]) { $rhOld.overrides.($w.Id) } else { $null }
                try {
                    $report = & (Join-Path $PSScriptRoot 'Invoke-ReleaseHealthCheck.ps1') -ReleaseId $ReleaseId -ReleaseVersion $releaseVersion -Tier $tier -Wave $w.Id `
                        -Cohorts $cohorts -RepoRoot $RepoRoot -ClassificationCommit $commit -AcceptedIds $accepted -Override $override -AsOf $now -KqlInvoker $KqlInvoker
                    $results.Add([pscustomobject]@{ Wave = $w; Tier = $tier; Cycles = $cycles; Report = $report })
                    $summary.Add("$($w.Label): $tier -> $($report.verdict.verdict)")
                } catch {
                    $summary.Add("$($w.Label): $tier failed: $($_.Exception.Message)")
                    Write-HealthAudit 'health-check-error' @{ wave = $w.Id; tier = $tier; error = $_.Exception.Message }
                }
            }

            $previousVersion = $cohorts.PreviousVersion
            Update-HealthState {
                param($rh)
                $rh | Add-Member -NotePropertyName releaseVersion -NotePropertyValue $releaseVersion -Force
                $rh | Add-Member -NotePropertyName previousVersion -NotePropertyValue $previousVersion -Force
                if ($commit) { $rh | Add-Member -NotePropertyName errorClassificationCommit -NotePropertyValue $commit -Force }
                foreach ($w in $cohorts.Waves) {
                    if (-not $rh.waves.PSObject.Properties[$w.Id]) {
                        $rh.waves | Add-Member -NotePropertyName $w.Id -NotePropertyValue ([pscustomobject]@{ label = $w.Label; isCanary = $w.IsCanary; units = @($w.Units); t0First = $w.T0First.ToString('o'); t0Last = $w.T0Last.ToString('o')
                            lastTripwireAt = $null; lastCheckpointCycle = 0; finalAt = $null; finalVerdict = $null; reports = @(); alertedKeys = @(); reportedKeys = @() })
                    } else {
                        $rw = $rh.waves.($w.Id); $rw.label = $w.Label; $rw.units = @($w.Units); $rw.t0Last = $w.T0Last.ToString('o')
                    }
                }
                foreach ($r in $results) {
                    $rw = $rh.waves.($r.Wave.Id); $rep = $r.Report; $at = [datetime]::UtcNow.ToString('o')
                    $rw.reports = @(@($rw.reports) + [pscustomobject]@{ tier = $r.Tier; at = $at; verdict = $rep.verdict.verdict; json = $rep.files.json; html = $rep.files.html })
                    $rw.lastTripwireAt = $at
                    if ($r.Tier -ne 'tripwire') { $rw.lastCheckpointCycle = $r.Cycles }
                    $open = @($rep.findings | Where-Object { -not $_.suppressed -and -not $_.accepted })
                    $newSev1 = @($open | Where-Object { $_.severity -eq 'Sev1' -and $_.key -notin @($rw.alertedKeys) })
                    $newInv = @($open | Where-Object { $_.severity -eq 'Investigate' -and $_.key -notin @($rw.reportedKeys) })
                    $notify = $null
                    if ($r.Tier -eq 'final') {
                        $rw.finalVerdict = $rep.verdict.verdict
                        if ($rep.verdict.verdict -ne 'INCONCLUSIVE') { $rw.finalAt = $at }
                        if ($rep.verdict.verdict -ne 'INCONCLUSIVE' -or -not $rw.PSObject.Properties['inconclusiveNotified'] -or -not $rw.inconclusiveNotified) {
                            $notify = @{ kind = 'verdict'; eventKey = 'release-health-' + $rep.verdict.verdict.ToLowerInvariant() }
                            if ($rep.verdict.verdict -eq 'INCONCLUSIVE') { $rw | Add-Member -NotePropertyName inconclusiveNotified -NotePropertyValue $true -Force }
                        }
                    } elseif ($newSev1.Count) { $notify = @{ kind = 'early-warning'; eventKey = 'release-health-early-warning' } }
                    elseif ($r.Tier -eq 'checkpoint' -and $newInv.Count) { $notify = @{ kind = 'interim'; eventKey = 'release-health-interim' } }
                    $rw.alertedKeys = @(@($rw.alertedKeys) + @($newSev1.key) | Select-Object -Unique)
                    $rw.reportedKeys = @(@($rw.reportedKeys) + @($newInv.key) | Select-Object -Unique)
                    if ($notify) {
                        $nid = 'rh-' + $r.Wave.Id + '-' + $r.Tier + '-' + [datetime]::UtcNow.ToString('yyyyMMddHHmmss')
                        $html = if ($notify.kind -eq 'verdict') { $rep.files.html } else { $rep.files.html -replace '\.html$', ".$($notify.kind).html" }
                        if ($notify.kind -ne 'verdict') { ConvertTo-HealthReportHtml -Report $rep -Kind $notify.kind -ReleaseName $ReleaseId | Set-Content -LiteralPath $html -Encoding UTF8 }
                        $rh.notifications | Add-Member -NotePropertyName $nid -NotePropertyValue ([pscustomobject]@{
                            id = $nid; kind = $notify.kind; eventKey = $notify.eventKey; waveId = $r.Wave.Id; waveLabel = $r.Wave.Label; tier = $r.Tier; verdict = $rep.verdict.verdict
                            subject = (Get-HealthSubject -Report $rep -Kind $notify.kind -ReleaseName $ReleaseId); json = $rep.files.json; html = $html
                            status = 'pending'; attempts = 0; createdAt = $at }) -Force
                    }
                }
                $rh | Add-Member -NotePropertyName running -NotePropertyValue $null -Force
                $rh | Add-Member -NotePropertyName lastRunSummary -NotePropertyValue ($summary -join '; ') -Force
                $rh | Add-Member -NotePropertyName lastRunCompletedAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            }
            foreach ($r in $results) { Write-HealthAudit 'health-check' @{ wave = $r.Wave.Id; label = $r.Wave.Label; tier = $r.Tier; verdict = $r.Report.verdict.verdict; sev1 = $r.Report.verdict.counts.sev1; investigate = $r.Report.verdict.counts.investigate; report = $r.Report.files.json } }
        } catch {
            $err = $_.Exception.Message
            Write-HealthAudit 'health-run-error' @{ error = $err }
            try { Update-HealthState { param($rh) $rh | Add-Member -NotePropertyName running -NotePropertyValue $null -Force; $rh | Add-Member -NotePropertyName lastRunSummary -NotePropertyValue "error: $err" -Force } } catch { }
            throw
        }
        return ($summary -join '; ')
    }
}
