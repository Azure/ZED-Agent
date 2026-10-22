param([Parameter(Mandatory)][string]$ReleaseId)
$ErrorActionPreference = 'Stop'
$stateFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/state.json"
$lockFile  = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/watcher.lock"
$stateLock = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/state.json.lock"

. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')
. (Join-Path $PSScriptRoot 'lib\RunCompletionWaitLib.ps1')

# Load service config once for watcher-tunable settings (test-mode interval, etc.)
$cfg = $null
try { $cfg = & (Join-Path $PSScriptRoot 'Load-ServiceConfig.ps1') } catch { $cfg = $null }
$testModeIntervalCap = 1800
if ($cfg -and $cfg.watcherTestModePollIntervalSeconds) { $testModeIntervalCap = [int]$cfg.watcherTestModePollIntervalSeconds }

# Write lock file with PID
@{ pid = $PID; startedAt = (Get-Date -Format 'o') } | ConvertTo-Json | Set-Content $lockFile -Encoding UTF8

$retryCount = 0; $maxRetries = 3; $baseDelay = 30
$authFailNotified = $false

function Get-AzToken([string]$Resource) {
    # Returns token string or $null on auth error (caller decides how to handle).
    # Wrapped in a Start-Job with a 30s timeout so a hung `az` subprocess can't
    # freeze the entire watcher loop (root cause of 2026-05 hibernation outage).
    # ADO must be requested by its AAD app ID: `--resource https://dev.azure.com` fails with
    # AADSTS500011 (resource principal not found) in the Microsoft tenant, which silently
    # stalled every ADO poll in an auth-failure loop (release 2026-10, Step 2 FI PR watch).
    if ($Resource -match '^https://(dev\.azure\.com|app\.vssps\.visualstudio\.com)/?$') {
        $Resource = '499b84ac-1321-427f-aa17-267ca6975798'
    }
    $job = Start-Job -ScriptBlock {
        param($r)
        $out = az account get-access-token --resource $r --query accessToken -o tsv 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = "$out" }
    } -ArgumentList $Resource
    if (-not (Wait-Job $job -Timeout 30)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw 'az token acquisition timed out after 30s'
    }
    $r = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($r.ExitCode -ne 0) {
        $msg = $r.Output
        if ($msg -match 'AADSTS|invalid_resource|Status_IncorrectConfiguration|InteractionRequired') {
            return $null  # Auth error — recoverable, don't throw
        }
        throw "az token error: $msg"  # Non-auth error — let caller's catch handle it
    }
    return $r.Output
}

function Write-AuthFailureAudit([string]$ReleaseId, [string]$Action) {
    $auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
    @{ ts = (Get-Date -Format 'o'); event = 'auth-token-expired'; action = $Action
       message = 'Azure CLI token expired. Run: az login --scope https://dev.azure.com/.default'
    } | ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
# Approval side-channel (opt-in: service-config operational.approvalWatchEnabled):
# every ZED-triggered deployment run (canary, rollback, roll-forward, production,
# private stamp) that is waiting on the OneBranch Approval Service / an ADO approval
# gets an email + Teams message with the approval link, reminders and an expiry
# alert (Invoke-ApprovalWatch.ps1). Throttled to operational.approvalPollIntervalSeconds
# (default 600) so it also runs during the (hour-long) chunked sleep.
# Disabled (default): the legacy poll-ado-pipelines Teams post of new approval links.
# ─────────────────────────────────────────────────────────────────────────────
$script:lastApprovalSync = [datetime]::MinValue
$script:approvalPollSeconds = 600
$script:approvalWatchEnabled = $false
try {
    $svcCfgPath = Join-Path (Get-Location) '.github/skills/zed-agent/service-config.json'
    if (Test-Path $svcCfgPath) {
        $svcCfgOp = (Get-Content $svcCfgPath -Raw | ConvertFrom-Json).operational
        if ($svcCfgOp -and $svcCfgOp.PSObject.Properties['approvalPollIntervalSeconds'] -and [int]$svcCfgOp.approvalPollIntervalSeconds -ge 60) { $script:approvalPollSeconds = [int]$svcCfgOp.approvalPollIntervalSeconds }
        if ($svcCfgOp -and $svcCfgOp.PSObject.Properties['approvalWatchEnabled'] -and $svcCfgOp.approvalWatchEnabled -eq $true) { $script:approvalWatchEnabled = $true }
    }
} catch { }
function Invoke-ApprovalSideChannel {
    if (-not $script:approvalWatchEnabled) { return }
    if (((Get-Date) - $script:lastApprovalSync).TotalSeconds -lt $script:approvalPollSeconds) { return }
    $script:lastApprovalSync = Get-Date
    try {
        $awScript = Join-Path $PSScriptRoot 'Invoke-ApprovalWatch.ps1'
        if (-not (Test-Path $awScript)) { return }
        $awArgs = @{
            Action      = 'Sync'
            ReleaseId   = $ReleaseId
            StateFile   = $stateFile
            StateLock   = $stateLock
            AuditFile   = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl")
            ReleaseFile = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json")
        }
        $tokenAw = Get-AzToken "https://dev.azure.com"
        if ($tokenAw) { $awArgs.AccessToken = $tokenAw }
        $aw = & $awScript @awArgs
        foreach ($ev in @($aw.NotifyEvents)) {
            & copilot --agent=ZedAgent -p "approval $($ev.event) $($ev.id) for release $ReleaseId" --allow-all --autopilot --no-ask-user -s
        }
    } catch {
        $auditFileAwErr = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'approval-side-channel-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFileAwErr -Encoding UTF8
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Canary schedule guard (e.g. BCM EA-CAN): pause the pipeline's own deployments
# (UI schedule trigger and/or an on/off variable) once ZED's Step 5 run of it
# succeeds, cancel runs ZED did not queue until Step 6 is signed off, then
# restore. Pure REST; the agent is only invoked to send emails. Non-fatal.
# Throttled to operational.scheduleGuardPollIntervalSeconds (default 300) and
# also called during the chunked sleep — a develop run needs ~20 min before it
# reaches its deploy stage, so foreign runs are cancelled in time.
# ─────────────────────────────────────────────────────────────────────────────
$script:lastScheduleGuardSync = [datetime]::MinValue
$script:scheduleGuardPollSeconds = 300
try {
    if ($svcCfgOp -and $svcCfgOp.PSObject.Properties['scheduleGuardPollIntervalSeconds'] -and [int]$svcCfgOp.scheduleGuardPollIntervalSeconds -ge 60) { $script:scheduleGuardPollSeconds = [int]$svcCfgOp.scheduleGuardPollIntervalSeconds }
} catch { }
function Invoke-ScheduleGuardSideChannel {
    if (((Get-Date) - $script:lastScheduleGuardSync).TotalSeconds -lt $script:scheduleGuardPollSeconds) { return }
    $script:lastScheduleGuardSync = Get-Date
    try {
        $sgScript = Join-Path $PSScriptRoot 'Invoke-ScheduleGuard.ps1'
        if (-not (Test-Path $sgScript) -or -not (Test-Path $stateFile)) { return }
        $sgState = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $sgStep5 = ($sgState.steps | Where-Object { $_.number -eq 5 }).status
        $sgActive = $sgState.PSObject.Properties['scheduleGuards'] -and $sgState.scheduleGuards -and
            @($sgState.scheduleGuards.PSObject.Properties | Where-Object { $_.Value.status -match '^(disabled|preexisting|disable-failed|restore-failed)$' }).Count -gt 0
        if ($sgStep5 -notin @('in-progress', 'completed') -and -not $sgActive) { return }
        $sgArgs = @{
            Action      = 'Sync'
            ReleaseId   = $ReleaseId
            StateFile   = $stateFile
            StateLock   = $stateLock
            AuditFile   = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl")
            ReleaseFile = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json")
        }
        $tokenSg = Get-AzToken "https://dev.azure.com"
        if ($tokenSg) { $sgArgs.AccessToken = $tokenSg }
        $sg = & $sgScript @sgArgs
        foreach ($ev in @($sg.NotifyEvents)) {
            # "<event>:<key>" or "<event>:<key>:<runId>" (run cancelled / cancel failed)
            $evName, $evKey, $evRun = $ev -split ':', 3
            $runPart = if ($evRun) { " run $evRun" } else { '' }
            & copilot --agent=ZedAgent -p "schedule guard $evName $evKey$runPart for release $ReleaseId" --allow-all --autopilot --no-ask-user -s
        }
    } catch {
        $auditFileSgErr = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'schedule-guard-side-channel-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFileSgErr -Encoding UTF8
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Revert bits side track (revertBits.prepareDuringCanaryBvt): while Step 6 runs,
# follow the revert bits PR → reuse/queue the revert build → 'ready', so Step 7
# can roll back with it right after approve-bvt (Invoke-RevertBitsTrack.ps1).
# Throttled to revertBits.prPollIntervalSeconds (default 900); also runs during
# the chunked sleep. The agent is only invoked to send the event emails.
# ─────────────────────────────────────────────────────────────────────────────
$script:lastRevertBitsSync = [datetime]::MinValue
$script:revertBitsPollSeconds = 900
try {
    $rbCfgW = (Get-Content (Join-Path (Get-Location) '.github/skills/zed-agent/service-config.json') -Raw | ConvertFrom-Json).revertBits
    if ($rbCfgW -and $rbCfgW.PSObject.Properties['prPollIntervalSeconds'] -and [int]$rbCfgW.prPollIntervalSeconds -ge 60) { $script:revertBitsPollSeconds = [int]$rbCfgW.prPollIntervalSeconds }
} catch { }
function Invoke-RevertBitsSideChannel {
    if (((Get-Date) - $script:lastRevertBitsSync).TotalSeconds -lt $script:revertBitsPollSeconds) { return }
    $script:lastRevertBitsSync = Get-Date
    try {
        $rbScript = Join-Path $PSScriptRoot 'Invoke-RevertBitsTrack.ps1'
        if (-not (Test-Path $rbScript) -or -not (Test-Path $stateFile)) { return }
        $rbState = (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).revertBits
        if (-not $rbState -or [string]$rbState.phase -notin @('pr-open', 'queue-build', 'building')) { return }
        $rbArgs = @{
            Action      = 'Poll'
            ReleaseId   = $ReleaseId
            StateFile   = $stateFile
            StateLock   = $stateLock
            AuditFile   = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl")
            ReleaseFile = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json")
        }
        $tokenRb = Get-AzToken "https://dev.azure.com"
        if ($tokenRb) { $rbArgs.AccessToken = $tokenRb }
        $rb = & $rbScript @rbArgs
        if ($rb.NotifyEvent) {
            & copilot --agent=ZedAgent -p "revert bits $($rb.NotifyEvent) for release $ReleaseId" --allow-all --autopilot --no-ask-user -s
        }
    } catch {
        $auditFileRbErr = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'revert-bits-side-channel-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFileRbErr -Encoding UTF8
    }
}
# ─────────────────────────────────────────────────────────────────────────────
# EV2 "deployment done" for pipeline runs that keep running through a long
# post-deployment managed validation (BCM canary: Canary-ManagedValidation, ~24 h).
# pipeline-catalog.json → canary.<key>.deploymentDoneWhen = { ev2StepStarted, portalLinkTask }.
# A poll-ado-pipelines target of such a pipeline becomes status 'deployed' (counts as
# done) once every region stage succeeded, without waiting for managed validation to start.
# ─────────────────────────────────────────────────────────────────────────────
$script:ev2RuleCache = $null
function Get-DeploymentDoneRules {
    if ($null -ne $script:ev2RuleCache) { return $script:ev2RuleCache }
    $rules = @{}
    try {
        $cat = Get-Content (Join-Path (Get-Location) '.github/skills/zed-agent/pipeline-catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $svcAdo = (Get-Content (Join-Path (Get-Location) '.github/skills/zed-agent/service-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).ado
        if ($cat.PSObject.Properties['canary'] -and $cat.canary) {
            foreach ($p in $cat.canary.PSObject.Properties) {
                $w = if ($p.Value.PSObject.Properties['deploymentDoneWhen']) { $p.Value.deploymentDoneWhen } else { $null }
                if (-not $w -or -not $w.ev2StepStarted -or -not $p.Value.id) { continue }
                $rules[[string]$p.Value.id] = [pscustomobject]@{
                    key = $p.Name; step = [string]$w.ev2StepStarted
                    task = $(if ($w.PSObject.Properties['portalLinkTask'] -and $w.portalLinkTask) { [string]$w.portalLinkTask } else { 'Ev2 Managed SDP Region Agnostic' })
                    org = [string]$svcAdo.organization; project = [string]$svcAdo.project
                }
            }
        }
    } catch { }
    $script:ev2RuleCache = $rules
    return $rules
}
function Update-TargetFromEv2 {
    param($Target, $Run, $Rule, [string]$AdoToken)
    $auditEv2 = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
    try {
        $p = & (Join-Path $PSScriptRoot 'EV2\Get-Ev2DeploymentProgress.ps1') -RunId ([long]$Run.id) -StepName $Rule.step -PortalLinkTask $Rule.task -Organization $Rule.org -Project $Rule.project -AdoToken $AdoToken
        $info = [pscustomobject]@{
            phase = $p.Phase; pipelineKey = $Rule.key; rolloutId = $p.RolloutId; portalUrl = $p.PortalUrl; rolloutStatus = $p.RolloutStatus
            validationStep = $p.ValidationStep; validationStatus = $p.ValidationStatus; validationStartedAt = $p.ValidationStartedAt
            deployedAt = $p.DeployedAt; reason = $p.Reason; error = $p.Error; checkedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $Target | Add-Member -NotePropertyName ev2 -NotePropertyValue $info -Force
        if ($p.Phase -in @('deployed', 'failed')) {
            $Target | Add-Member -NotePropertyName status -NotePropertyValue $p.Phase -Force
            @{ ts = (Get-Date -Format 'o'); event = "ev2-$($p.Phase)"; runId = $Run.id; pipelineKey = $Rule.key; rolloutId = $p.RolloutId; portalUrl = $p.PortalUrl; deployedAt = $p.DeployedAt; validationStatus = $p.ValidationStatus; reason = $p.Reason } |
                ConvertTo-Json -Compress | Add-Content $auditEv2 -Encoding UTF8
        }
    } catch {
        @{ ts = (Get-Date -Format 'o'); event = 'ev2-progress-error'; runId = $Run.id; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditEv2 -Encoding UTF8
    }
}

while ($true) {
    if (-not (Test-Path $stateFile)) { Start-Sleep -Seconds 30; continue }
    $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.status -in @('completed','stopped')) { break }

    # ─────────────────────────────────────────────────────────────────────────
    # Heartbeat — always-on "I'm alive" audit entry at top of every iteration.
    # Lets `status` / debugging answer "is the watcher actually running?" by
    # tailing audit.jsonl, independent of whether any directive made progress.
    # If the most recent heartbeat is older than ~2× the poll interval, the
    # watcher is frozen (DevBox hibernation, hung I/O, etc.) — not just idle.
    # ─────────────────────────────────────────────────────────────────────────
    try {
        $auditHb = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'watcher-heartbeat'; pid = $PID; directive = $state.watcherDirective.action } |
            ConvertTo-Json -Compress | Add-Content $auditHb -Encoding UTF8
    } catch { <# heartbeat is best-effort; never fail the loop on it #> }

    # ─────────────────────────────────────────────────────────────────────────
    # Drift-halt reminder (Layer 3) — any step in `failed-drift` is a soft halt
    # waiting on the release owner to reply `mitigated` or `approve drift` in
    # Teams. Re-post the Teams notification once after 24h with no progress,
    # so the thread bubbles back up. Status stays `failed-drift` — the watcher
    # does NOT auto-resume; the owner must drive re-entry via the agent.
    # ─────────────────────────────────────────────────────────────────────────
    $driftStep = $state.steps | Where-Object { $_.status -eq 'failed-drift' } | Select-Object -First 1
    if ($driftStep -and $driftStep.driftPayload -and $driftStep.driftPayload.haltedAt -and -not $driftStep.driftPayload.reminderSentAt) {
        $haltedAt = [datetime]$driftStep.driftPayload.haltedAt
        if ((Get-Date).ToUniversalTime() -gt $haltedAt.ToUniversalTime().AddHours(24)) {
            try {
                $invokeDriftHalt = Join-Path (Get-Location) ".github/skills/zed-agent/scripts/Invoke-DriftHalt.ps1"
                $rowsForReminder = @($driftStep.driftPayload.rows | ForEach-Object { @{ stampName = $_.stampName; reason = $_.reason; source = $_.source } })
                & $invokeDriftHalt -ReleaseId $ReleaseId -StepNumber $driftStep.number `
                    -StepName $driftStep.name -Scope $driftStep.driftPayload.scope `
                    -DriftRows $rowsForReminder -ReleaseOwner $state.releaseOwner `
                    -Branch $state.branch -SkipStateUpdate | Out-Null

                Invoke-WithStateLock -LockFile $stateLock -Action ({
                    $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $ds = $latest.steps | Where-Object { $_.number -eq $driftStep.number }
                    if ($ds) {
                        if (-not $ds.driftPayload.PSObject.Properties['reminderSentAt']) {
                            Add-Member -InputObject $ds.driftPayload -MemberType NoteProperty -Name reminderSentAt -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force
                        } else { $ds.driftPayload.reminderSentAt = (Get-Date).ToUniversalTime().ToString('o') }
                    }
                    $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
                }.GetNewClosure())

                $auditDrift = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'drift-halt-reminder'; step = $driftStep.number; haltedAt = $driftStep.driftPayload.haltedAt } |
                    ConvertTo-Json -Compress | Add-Content $auditDrift -Encoding UTF8
            } catch {
                # Reminder is best-effort; don't take down the watcher
                $auditDrift = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'drift-halt-reminder-failed'; step = $driftStep.number; error = $_.Exception.Message } |
                    ConvertTo-Json -Compress | Add-Content $auditDrift -Encoding UTF8
            }
        }
    }

    $dir = $state.watcherDirective

    # ─────────────────────────────────────────────────────────────────────────
    # Step 3 ∥ Step 4 side-channel poll
    # Delegates to shared Invoke-Step4SideChannel.ps1 so both the watcher and
    # cloud cold-resume sessions use identical logic. Non-fatal.
    # ─────────────────────────────────────────────────────────────────────────
    try {
        $step4 = $state.steps | Where-Object { $_.number -eq 4 }
        if ($state.step4InlineCompleted -eq $true `
            -and $step4 -and $step4.status -eq 'in-progress' `
            -and $state.step4ExcelUrl) {
            $sideChannelScript = Join-Path $PSScriptRoot 'Invoke-Step4SideChannel.ps1'
            if (Test-Path $sideChannelScript) {
                $auditFileS4 = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                $tokenS4 = Get-AzToken "https://graph.microsoft.com"
                $s4Params = @{
                    ReleaseId   = $ReleaseId
                    StateFile   = $stateFile
                    StateLock   = $stateLock
                    AuditFile   = $auditFileS4
                }
                if ($tokenS4) { $s4Params.AccessToken = $tokenS4 }
                & $sideChannelScript @s4Params | Out-Null
            }
        }
    } catch {
        $auditFileS4Err = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'step4-side-channel-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFileS4Err -Encoding UTF8
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Private stamp upgrade side track (Step 5 ∥ … → joined at Step 13).
    # Advances last → current → awaiting-bvt with pure REST; the agent is only
    # invoked on a transition that needs an email (NotifyEvent). Non-fatal.
    # ─────────────────────────────────────────────────────────────────────────
    try {
        if ($state.PSObject.Properties['privateStampUpgrade'] -and $state.privateStampUpgrade -and
            $state.privateStampUpgrade.status -match '^(inputs-ready|triggering|deploying|bvt-running|retrying)') {
            $psuScript = Join-Path $PSScriptRoot 'Invoke-PrivateStampUpgrade.ps1'
            if (Test-Path $psuScript) {
                $psuArgs = @{
                    Action    = 'Poll'
                    ReleaseId = $ReleaseId
                    StateFile = $stateFile
                    StateLock = $stateLock
                    AuditFile = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl")
                    ReleaseFile = (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json")
                }
                $tokenPsu = Get-AzToken "https://dev.azure.com"
                if ($tokenPsu) { $psuArgs.AccessToken = $tokenPsu }
                $psu = & $psuScript @psuArgs
                if ($psu.NotifyEvent) {
                    & copilot --agent=ZedAgent -p "private stamp upgrade $($psu.NotifyEvent) for release $ReleaseId" --allow-all --autopilot --no-ask-user -s
                }
            }
        }
    } catch {
        $auditFilePsuErr = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'private-stamp-side-channel-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFilePsuErr -Encoding UTF8
    }

    # Canary schedule guard: see Invoke-ScheduleGuardSideChannel (also runs during the sleep).
    Invoke-ScheduleGuardSideChannel
    Invoke-RevertBitsSideChannel

    Invoke-ApprovalSideChannel

    if (-not $dir -or $dir.action -eq 'none') { Start-Sleep -Seconds 30; continue }

    $conditionMet = $false
    if ($dir.action -eq 'wait-timer') {
        $now = Get-Date
        $waitField = if ($dir.waitUntil) { $dir.waitUntil } elseif ($dir.scheduledAt) { $dir.scheduledAt } else { $null }
        if (-not $waitField) { Start-Sleep -Seconds 30; continue }
        $scheduled = [datetime]$waitField
        $conditionMet = $now -ge $scheduled
        # Detect missed schedule: if more than 30 min late, notify release owner via email
        if ($conditionMet) {
            $delayMin = [math]::Round(($now - $scheduled).TotalMinutes)
            if ($delayMin -gt 30 -and -not $dir.missedNotified) {
                $dir.missedNotified = $true
                Invoke-WithStateLock -LockFile $stateLock -Action {
                    $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $latest.watcherDirective = $dir
                    $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
                }
                & copilot --agent=ZedAgent -p "missed schedule for release $ReleaseId region $($dir.region) scheduled at $waitField delay ${delayMin} minutes" --allow-all --autopilot --no-ask-user -s
            }
        }
    } elseif ($dir.action -eq 'poll-ado-pr') {
        # Step 2a/2b RI/FI PR: completed (merged) -> onSuccess; abandoned -> onFailure (stop polling).
        try {
            $token = Get-AzToken "https://dev.azure.com"
            if (-not $token) {
                if (-not $authFailNotified) { Write-AuthFailureAudit $ReleaseId $dir.action; $authFailNotified = $true }
                Start-Sleep -Seconds 300; continue
            }
            $authFailNotified = $false
            $pr = Invoke-RestMethod -Uri $dir.target -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 60 -ErrorAction Stop
            $retryCount = 0
            if ($pr.status -eq 'completed') {
                $conditionMet = $true
            } elseif ($pr.status -eq 'abandoned') {
                $auditPr = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'integration-pr-abandoned'; pullRequestId = $pr.pullRequestId; target = $dir.target } |
                    ConvertTo-Json -Compress | Add-Content $auditPr -Encoding UTF8
                Invoke-WithStateLock -LockFile $stateLock -Action {
                    $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $latest.watcherDirective = [pscustomobject]@{ action = 'none' }
                    $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
                }
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                Start-Sleep -Seconds 30; continue
            }
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
    } elseif ($dir.action -eq 'poll-ado-pipelines') {
        # Multi-pipeline polling: check all targets + detect approval links
        try {
            $token = Get-AzToken "https://dev.azure.com"
            if (-not $token) {
                if (-not $authFailNotified) { Write-AuthFailureAudit $ReleaseId $dir.action; $authFailNotified = $true }
                Start-Sleep -Seconds 300; continue  # 5-min retry, don't count toward maxRetries
            }
            $authFailNotified = $false
            $headers = @{ Authorization = "Bearer $token" }
            $allDone = $true; $anyFailed = $false
            $ev2Rules = Get-DeploymentDoneRules
            # waitForRunCompletion (serialization waits, e.g. "EV2 one rollout at a time" before
            # Steps 7/10/13/15): done ONLY when every ADO run has status 'completed' (any result) —
            # no deploymentDoneWhen 'deployed' shortcut, a foreign run's failed result is not a
            # failure of this release. See scripts/lib/RunCompletionWaitLib.ps1.
            $waitForCompletion = $dir.PSObject.Properties['waitForRunCompletion'] -and $dir.waitForRunCompletion -eq $true
            if ($waitForCompletion) {
                $rc = Update-RunCompletionTargets -Targets @($dir.targets) -GetRun {
                    param($tt) Invoke-RestMethod -Uri $tt.url -Headers $headers -TimeoutSec 60 -ErrorAction Stop
                }
                $allDone = $rc.AllDone
                foreach ($ct in $rc.Completed) {
                    $auditRc = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                    @{ ts = (Get-Date -Format 'o'); event = 'run-completed'; url = $ct.url; label = $ct.label; result = $ct.result; finishTime = $ct.finishTime; reason = 'waitForRunCompletion' } |
                        ConvertTo-Json -Compress | Add-Content $auditRc -Encoding UTF8
                }
            }
            foreach ($t in $(if ($waitForCompletion) { @() } else { $dir.targets })) {
                if ($t.status -in @('completed','failed','deployed')) { continue }
                $resp = Invoke-RestMethod -Uri $t.url -Headers $headers -TimeoutSec 60 -ErrorAction Stop
                if ($resp.status -eq 'completed') {
                    $t.status = if ($resp.result -eq 'succeeded') { 'completed' } else { 'failed' }
                } elseif ($resp.definition -and $ev2Rules.ContainsKey([string]$resp.definition.id)) {
                    # catalog deploymentDoneWhen: the run stays in progress for EV2's post-deployment
                    # managed validation (~24 h) — deployment is done once every region succeeded.
                    Update-TargetFromEv2 -Target $t -Run $resp -Rule $ev2Rules[[string]$resp.definition.id] -AdoToken $token
                }
                if ($t.status -eq 'failed') { $anyFailed = $true }
                if ($t.status -notin @('completed','failed','deployed')) { $allDone = $false }
            }

            # Approval links: with operational.approvalWatchEnabled the approval side-channel
            # (Invoke-ApprovalSideChannel) handles every watched run. Otherwise (default) the
            # legacy behaviour: scan these targets for new approval links and post them to Teams.
            if (-not $script:approvalWatchEnabled) {
            # Approval link detection: scan build logs for EV2 approval URLs (per-URL dedup)
            if (-not $dir.postedApprovalUrls) { $dir.postedApprovalUrls = @() }
            try {
                $scriptRoot = Join-Path (Get-Location) ".github/skills/zed-agent/scripts"
                . "$scriptRoot/Get-PipelineApprovalLinks.ps1"
                $builds = @($dir.targets | Where-Object { $_.status -notin @('completed','failed') } | ForEach-Object {
                    @{ pipelineName = $_.name; buildId = $_.buildId }
                })
                if ($builds.Count -gt 0) {
                    $links = Get-PipelineApprovalLinks -Builds $builds -AccessToken $token
                    # Collect only NEW approval links (not already posted)
                    $newRows = @(); $newEv2Links = @(); $newApprovalUrls = @()
                    foreach ($l in $links) {
                        foreach ($s in $l.stages) {
                            if ($s.approvalUrl -and $s.approvalUrl -notin $dir.postedApprovalUrls) {
                                $safeName = [System.Net.WebUtility]::HtmlEncode($l.pipelineName)
                                $safeStageName = [System.Net.WebUtility]::HtmlEncode($s.name)
                                $newRows += "<tr><td>$safeName</td><td>$safeStageName</td><td>$($s.status)</td><td><a href='$($s.approvalUrl)'>Approve</a></td><td><a href='$($l.buildUrl)'>Build</a></td></tr>"
                                $newApprovalUrls += $s.approvalUrl
                            }
                            if ($s.ev2RolloutUrl -and $s.ev2RolloutUrl -notin $dir.postedApprovalUrls) {
                                $safeName = [System.Net.WebUtility]::HtmlEncode($l.pipelineName)
                                $newEv2Links += "<a href='$($s.ev2RolloutUrl)'>$safeName</a><br>"
                            }
                        }
                    }
                    if ($newRows.Count -gt 0) {
                        # Post to Teams
                        . "$scriptRoot/Send-TeamsMessage.ps1"
                        $secretsFile = Join-Path (Get-Location) ".zed-agent/secrets.json"
                        if (Test-Path $secretsFile) {
                            $secrets = Get-Content $secretsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            # Use Teams chat name from watcher directive (set by agent from config routing)
                            $teamsChatName = if ($dir.teamsChatName) { $dir.teamsChatName } else { $null }
                            $convId = if ($teamsChatName -and $secrets.teamsChats.$teamsChatName) { $secrets.teamsChats.$teamsChatName } else { $null }
                            if ($convId) {
                                $releaseFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json"
                                $release = Get-Content $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
                                $templatePath = Join-Path (Get-Location) ".github/skills/zed-agent/templates/canary-approval-request.html"
                                . "$scriptRoot/Expand-Template.ps1"
                                . "$scriptRoot/Get-ScopeTemplateVars.ps1"
                                $vars = @{
                                    releaseId = $ReleaseId; buildVersion = $release.buildVersion; branch = $release.branch
                                    approvalRows = ($newRows -join "`n"); ev2Links = ($newEv2Links -join "`n")
                                    releaseOwner = if ($release.releaseOwner) { $release.releaseOwner } else { 'Release Owner' }
                                }
                                # L-18: comms must state the route/geography scope of the rollout.
                                foreach ($kv in (Get-ScopeTemplateVars -ReleaseId $ReleaseId).GetEnumerator()) {
                                    $vars[$kv.Key] = $kv.Value
                                }
                                Send-TeamsMessage -ConversationId $convId -TemplatePath $templatePath -Variables $vars
                                $dir.postedApprovalUrls += $newApprovalUrls
                                # Audit
                                $auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                                @{ ts = (Get-Date -Format 'o'); event = 'canary-approval-links-posted'; newCount = $newRows.Count; totalPosted = $dir.postedApprovalUrls.Count } |
                                    ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8
                            }
                        }
                    }
                }
            } catch {
                # Non-fatal — approval link detection is best-effort
                $auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'approval-link-scan-error'; error = $_.Exception.Message } |
                    ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8
            }
            }

            # Write updated target statuses back to state
            Invoke-WithStateLock -LockFile $stateLock -Action {
                $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $latest.watcherDirective = $dir
                $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
            }
            $conditionMet = $allDone
            if ($anyFailed) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $retryCount = 0
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
    } elseif ($dir.action -eq 'poll-onedrive-file') {
        # GAP-3: Excel completion polling via Graph API + ImportExcel
        # Tracker mode: the directive carries `tracker` = { sheetName, driveId, itemId } and the
        # fill % of the release's sheet comes from Invoke-CommitTracker.ps1 (required columns).
        if ($dir.PSObject.Properties['tracker'] -and $dir.tracker -and $dir.tracker.sheetName) {
            try {
                $tpArgs = @{ Action = 'Poll'; ReleaseId = $ReleaseId; SheetName = [string]$dir.tracker.sheetName }
                if ($dir.tracker.driveId) { $tpArgs.DriveId = [string]$dir.tracker.driveId }
                if ($dir.tracker.itemId) { $tpArgs.ItemId = [string]$dir.tracker.itemId }
                $tokenTr = Get-AzToken "https://graph.microsoft.com"
                if ($tokenTr) { $tpArgs.AccessToken = $tokenTr }
                $tp = & (Join-Path $PSScriptRoot 'Invoke-CommitTracker.ps1') @tpArgs
                if (-not $tp.Success) { throw $tp.Error }
                $auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'excel-poll'; mode = 'tracker'; sheet = $dir.tracker.sheetName; filled = $tp.Filled; total = $tp.TotalRows; pct = $tp.Pct } | ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8
                $conditionMet = ($tp.Pct -ge 100)
                $retryCount = 0
            } catch {
                $retryCount++
                if ($retryCount -ge $maxRetries) {
                    & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                    break
                }
                $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
                Start-Sleep -Seconds $delay; continue
            }
        } else {
        try {
            $token = Get-AzToken "https://graph.microsoft.com"
            if (-not $token) {
                if (-not $authFailNotified) { Write-AuthFailureAudit $ReleaseId $dir.action; $authFailNotified = $true }
                Start-Sleep -Seconds 300; continue
            }
            $authFailNotified = $false
            $headers = @{ Authorization = "Bearer $token" }
            $tempFile = Join-Path $env:TEMP "watcher_excel_$ReleaseId.xlsx"
            Invoke-RestMethod -Uri $dir.target -Headers $headers -OutFile $tempFile -TimeoutSec 60 -ErrorAction Stop
            if (-not (Get-Module -ListAvailable ImportExcel)) { Install-Module ImportExcel -Scope CurrentUser -Force }
            $rows = Import-Excel $tempFile -ErrorAction Stop
            $total = $rows.Count
            $filled = ($rows | Where-Object { $_.'Impact' -and $_.'Impact'.ToString().Trim() -ne '' }).Count
            $pct = if ($total -gt 0) { [math]::Round(($filled / $total) * 100) } else { 0 }
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            # Log progress to audit
            $auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
            @{ ts = (Get-Date -Format 'o'); event = 'excel-poll'; filled = $filled; total = $total; pct = $pct } | ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8
            $conditionMet = ($pct -ge 100)
            $retryCount = 0
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
        }
    } elseif ($dir.action -eq 'safefly-approval-poll') {
        # GAP-4: SafeFly approval polling via dedicated auth resource
        try {
            $scriptPath = Join-Path (Get-Location) ".github/skills/zed-agent/scripts/SafeFly/Get-SafeFlyApproval.ps1"
            $result = & $scriptPath -SafeFlyId $dir.safeFlyId
            $classification = $result.classification
            if ($classification -eq 'Approved') {
                $conditionMet = $true
            } elseif ($classification -in @('Rejected','Invalidated')) {
                & copilot --agent=ZedAgent -p "SafeFly request $($dir.safeFlyId) was $classification" --allow-all --autopilot --no-ask-user -s
                break
            }
            # 'Pending' → continue polling
            # Check timeout
            if ($dir.startedAt -and $dir.timeoutHours) {
                $elapsed = (Get-Date) - [datetime]$dir.startedAt
                if ($elapsed.TotalHours -gt $dir.timeoutHours) {
                    & copilot --agent=ZedAgent -p "SafeFly approval timed out after $($dir.timeoutHours)h for request $($dir.safeFlyId)" --allow-all --autopilot --no-ask-user -s
                    break
                }
            }
            $retryCount = 0
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p "SafeFly approval polling failed after $maxRetries retries: $_" --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
    } elseif ($dir.action -eq 'poll-ev2-rollout') {
        # EV2 rollout status polling — queries EV2 REST API for per-region diagnostics
        try {
            $scriptPath = Join-Path (Get-Location) ".github/skills/zed-agent/scripts/EV2/Get-Ev2RolloutStatus.ps1"
            $allResults = @()
            foreach ($t in $dir.targets) {
                $params = @{ ServiceGroup = $t.serviceGroup }
                if ($t.rolloutId) { $params.RolloutId = $t.rolloutId }
                else { $params.BuildId = $t.buildId }
                if ($t.rolloutInfra) { $params.RolloutInfra = $t.rolloutInfra }
                $result = & $scriptPath @params
                $allResults += $result
            }
            # Store diagnostics in state for agent to read
            Invoke-WithStateLock -LockFile $stateLock -Action {
                $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $latest | Add-Member -NotePropertyName 'ev2Diagnostics' -NotePropertyValue $allResults -Force
                $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
            }

            $anyFailed = @($allResults | Where-Object { $_.overallStatus -match 'Failed|Error|Faulted' })
            $allCompleted = @($allResults | Where-Object { $_.overallStatus -match 'Completed|Succeeded' }).Count -eq $allResults.Count

            if ($anyFailed.Count -gt 0) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $conditionMet = $allCompleted
            $retryCount = 0
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
    } elseif ($dir.action -eq 'poll-bvt-releases') {
        # Steps 6/8/11: the BVT releases created right after the canary deployment
        # (Invoke-BvtReleases.ps1 -Action Start) — continue once all of their stages finished.
        try {
            $token = Get-AzToken "https://dev.azure.com"
            if (-not $token) {
                if (-not $authFailNotified) { Write-AuthFailureAudit $ReleaseId $dir.action; $authFailNotified = $true }
                Start-Sleep -Seconds 300; continue
            }
            $authFailNotified = $false
            $bv = & (Join-Path $PSScriptRoot 'Invoke-BvtReleases.ps1') -Action Poll -ReleaseId $ReleaseId -Step ([int]$dir.step) `
                -StateFile $stateFile -StateLock $stateLock `
                -AuditFile (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl") `
                -ReleaseFile (Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json") -AccessToken $token
            if ($bv.Phase -in @('failed', 'timed-out')) {
                Invoke-WithStateLock -LockFile $stateLock -Action {
                    $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $latest.watcherDirective = [pscustomobject]@{ action = 'none' }
                    $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
                }
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                Start-Sleep -Seconds 30; continue
            }
            if ($bv.Error) { throw $bv.Error }   # transient read error — retry with backoff
            $retryCount = 0
            $conditionMet = ($bv.Phase -eq 'completed')
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
    } else {
        # Single-target polling (poll-ado-build, poll-ado-pipelines, poll-onedrive-file, wait-timer, safefly-approval-poll)
        try {
            $resource = if ($dir.action -match 'onedrive') { "https://graph.microsoft.com" } else { "https://dev.azure.com" }
            $token = Get-AzToken $resource
            if (-not $token) {
                if (-not $authFailNotified) { Write-AuthFailureAudit $ReleaseId $dir.action; $authFailNotified = $true }
                Start-Sleep -Seconds 300; continue
            }
            $authFailNotified = $false
            $headers = @{ Authorization = "Bearer $token" }
            $resp = Invoke-RestMethod -Uri $dir.target -Headers $headers -TimeoutSec 60 -ErrorAction Stop
            if ($dir.successCondition -match '^\$\.(\w+)\s*==\s*''(.+)''$') {
                $conditionMet = ($resp.$($Matches[1]) -eq $Matches[2])
            } elseif ($dir.successCondition -match '^\$\.(\w+)\s*>\s*''(.+)''$') {
                $conditionMet = ($resp.$($Matches[1]) -gt $Matches[2])
            } else {
                # Unrecognized successCondition shape — log and treat as not-met so polling continues
                # rather than silently looping forever with $conditionMet always $false.
                $auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'invalid-success-condition'
                   successCondition = $dir.successCondition
                   message = "successCondition must match `$.<field> == '<value>' or `$.<field> > '<value>'" } |
                    ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8
                $conditionMet = $false
            }
            $retryCount = 0
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                & copilot --agent=ZedAgent -p $dir.onFailure --allow-all --autopilot --no-ask-user -s
                break
            }
            $delay = [math]::Min($baseDelay * [math]::Pow(2, $retryCount - 1), 300)
            Start-Sleep -Seconds $delay; continue
        }
    }

    if ($conditionMet) {
        $retryCount = 0
        & copilot --agent=ZedAgent -p $dir.onSuccess --allow-all --autopilot --no-ask-user -s
    }
    $interval = if ($dir.pollIntervalSeconds) { $dir.pollIntervalSeconds } else { 3600 }
    # Test mode: cap poll interval for faster iteration. Cap value comes from
    # service-config.watcherTestModePollIntervalSeconds (default 1800).
    try {
        $releaseFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json"
        if (Test-Path $releaseFile) {
            $release = Get-Content $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($release.testMode -eq $true) { $interval = [math]::Min($interval, $testModeIntervalCap) }
        }
    } catch { <# Ignore — use default interval on parse failure #> }
    # Chunked sleep: break the (possibly hour-long) poll interval into 60s
    # slices so the loop stays interruptible and a hibernation event can't
    # freeze the process mid-sleep for the full interval. Each tick also
    # checks for an external stop signal (release status flipped to
    # completed/stopped) without waiting for the full interval to elapse.
    $remaining = $interval
    while ($remaining -gt 0) {
        $chunk = [math]::Min($remaining, 60)
        Start-Sleep -Seconds $chunk
        $remaining -= $chunk
        # Approval requests can't wait an hour — check them on their own (shorter) cadence.
        Invoke-ScheduleGuardSideChannel
        Invoke-RevertBitsSideChannel
        Invoke-ApprovalSideChannel
        if (Test-Path $stateFile) {
            try {
                $peek = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($peek.status -in @('completed','stopped')) { $remaining = 0 }
            } catch { <# transient read race — keep sleeping #> }
        }
    }
}
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
