<#
.SYNOPSIS
    Cold-resume entry point for ZED cloud sessions. Discovers the active release,
    loads durable state, determines the current step, and returns a machine-readable
    verdict of what should happen next.

.DESCRIPTION
    In the cloud execution model, every wake-up is a brand-new session with zero
    conversational memory. This script is the first thing a woken session runs.
    It replaces the watcher's `onSuccess` prompt mechanism by self-discovering
    context from committed state.

    Flow:
    1. Scan for an active release (there may be none — clean no-op exit)
    2. Load the durable state (release.json, state.json)
    3. Run Step 4 side-channel check (on every wake-up regardless of current step)
    4. Determine the current step and its status
    5. Evaluate whether the step's wait condition is now satisfied
    6. Return a verdict object

    This script is READONLY in terms of step transitions — it evaluates conditions
    but does NOT advance steps. The caller (agent session) acts on the verdict.

.PARAMETER RepoRoot
    Repository root. Defaults to current directory.

.OUTPUTS
    PSCustomObject with:
      Action         - 'none' | 'execute-step' | 'resume-step' | 'wait' | 'approval-needed' | 'failed' | 'completed'
      ReleaseId      - Active release ID (null if none found)
      CurrentStep    - Step number
      StepName       - Step name
      StepStatus     - Current step status
      WatcherDirective - The active watcher directive (if any)
      DirectiveEvaluation - Result of evaluating the directive condition
      Message        - Human-readable description
      Step4SideChannel - Result of Invoke-Step4SideChannel (if it ran)
      PrivateStampSideChannel - Result of Invoke-PrivateStampUpgrade -Action Poll (if it ran);
                       a non-empty .NotifyEvent means the session must send that email
                       (see step-behaviors.md → Private stamp upgrade test)
      ScheduleGuardSideChannel - Result of Invoke-ScheduleGuard -Action Sync (if it ran);
                       every .NotifyEvents entry ("<event>:<pipelineKey>[:<runId>]") is an email to send
                       (see step-behaviors.md → Canary schedule guard)
      ApprovalSideChannel - Result of Invoke-ApprovalWatch -Action Sync; every .NotifyEvents entry
                       ({ event, id }) is an approval email + Teams message to send
                       (see step-behaviors.md → Approval requests)
      RevertBitsSideChannel - Result of Invoke-RevertBitsTrack -Action Poll (if it ran); a non-empty
                       .NotifyEvent (revert-bits-ready / revert-bits-failed) is an email to send
                       (see step-behaviors.md → Step 7 — Revert bits → Prepared during the canary BVT)
      StatePaths     - Resolved state paths object
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Get-Location }

$verdict = [PSCustomObject]@{
    Action              = 'none'
    ReleaseId           = $null
    CurrentStep         = $null
    StepName            = $null
    StepStatus          = $null
    WatcherDirective    = $null
    DirectiveEvaluation = $null
    Message             = 'No active release found'
    Step4SideChannel    = $null
    PrivateStampSideChannel = $null
    ScheduleGuardSideChannel = $null
    ApprovalSideChannel = $null
    RevertBitsSideChannel = $null
    StatePaths          = $null
}

# ── Step 1: Discover active release ──
# Search both .zed-release/ (durable/cloud) and .zed-agent/ (local) for releases
$releaseDirs = @()
foreach ($base in @('.zed-release', '.zed-agent')) {
    $releasesDir = Join-Path $RepoRoot "$base/releases"
    if (Test-Path $releasesDir) {
        $candidates = Get-ChildItem -Path $releasesDir -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $candidates) {
            $stateFile = Join-Path $dir.FullName 'state.json'
            if (Test-Path $stateFile) {
                $releaseDirs += [PSCustomObject]@{
                    ReleaseId = $dir.Name
                    StateFile = $stateFile
                    Base      = $base
                    Dir       = $dir.FullName
                }
            }
        }
    }
}

if ($releaseDirs.Count -eq 0) {
    # No releases found — clean no-op exit (most cron ticks will hit this)
    return $verdict
}

# Find the active release (status not 'completed' or 'stopped')
$activeRelease = $null
foreach ($rel in $releaseDirs) {
    try {
        $state = Get-Content $rel.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.status -notin @('completed', 'stopped')) {
            $activeRelease = [PSCustomObject]@{
                ReleaseId = $rel.ReleaseId
                State     = $state
                StateFile = $rel.StateFile
                Base      = $rel.Base
                Dir       = $rel.Dir
            }
            break
        }
    } catch {
        # Corrupt state file — skip
        continue
    }
}

if (-not $activeRelease) {
    return $verdict
}

$verdict.ReleaseId = $activeRelease.ReleaseId

# ── Step 2: Resolve paths ──
$resolveScript = Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1'
$paths = & $resolveScript -ReleaseId $activeRelease.ReleaseId -RepoRoot $RepoRoot
$verdict.StatePaths = $paths

$state = $activeRelease.State

# ── Step 3: Run Step 4 side-channel (on EVERY wake-up, regardless of current step) ──
try {
    $sideChannelScript = Join-Path $PSScriptRoot 'Invoke-Step4SideChannel.ps1'
    if (Test-Path $sideChannelScript) {
        $scratchLock  = Join-Path $paths.ScratchDir 'state.json.lock'
        $s4Result = & $sideChannelScript `
            -ReleaseId $activeRelease.ReleaseId `
            -StateFile $activeRelease.StateFile `
            -StateLock $scratchLock `
            -AuditFile $paths.AuditFile
        $verdict.Step4SideChannel = $s4Result

        # Reload state if side-channel modified it
        if ($s4Result.StepCompleted) {
            $state = Get-Content $activeRelease.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
} catch {
    # Side-channel is non-fatal
    $verdict.Step4SideChannel = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
}

# ── Step 3b: Private stamp upgrade side track (every wake-up, regardless of current step) ──
try {
    $psuScript = Join-Path $PSScriptRoot 'Invoke-PrivateStampUpgrade.ps1'
    if ((Test-Path $psuScript) -and $state.PSObject.Properties['privateStampUpgrade'] -and $state.privateStampUpgrade -and
        $state.privateStampUpgrade.status -match '^(inputs-ready|triggering|deploying|bvt-running|retrying)') {
        $verdict.PrivateStampSideChannel = & $psuScript -Action Poll `
            -ReleaseId $activeRelease.ReleaseId `
            -StateFile $activeRelease.StateFile `
            -StateLock (Join-Path $paths.ScratchDir 'state.json.lock') `
            -AuditFile $paths.AuditFile `
            -ReleaseFile $paths.ReleaseFile
        if ($verdict.PrivateStampSideChannel.Transition) {
            $state = Get-Content $activeRelease.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
} catch {
    $verdict.PrivateStampSideChannel = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
}

# ── Step 3c: Canary schedule guard (pause/restore e.g. EA-CAN enableSchedule) ──
try {
    $sgScript = Join-Path $PSScriptRoot 'Invoke-ScheduleGuard.ps1'
    $sgStep5 = ($state.steps | Where-Object { $_.number -eq 5 }).status
    $sgActive = $state.PSObject.Properties['scheduleGuards'] -and $state.scheduleGuards -and
        @($state.scheduleGuards.PSObject.Properties | Where-Object { $_.Value.status -match '^(disabled|preexisting|disable-failed|restore-failed)$' }).Count -gt 0
    if ((Test-Path $sgScript) -and ($sgStep5 -in @('in-progress', 'completed') -or $sgActive)) {
        $verdict.ScheduleGuardSideChannel = & $sgScript -Action Sync `
            -ReleaseId $activeRelease.ReleaseId `
            -StateFile $activeRelease.StateFile `
            -StateLock (Join-Path $paths.ScratchDir 'state.json.lock') `
            -AuditFile $paths.AuditFile `
            -ReleaseFile $paths.ReleaseFile
        if (@($verdict.ScheduleGuardSideChannel.Results).Count -gt 0) {
            $state = Get-Content $activeRelease.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
} catch {
    $verdict.ScheduleGuardSideChannel = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
}

# ── Step 3d: Approval requests (OneBranch Approval Service / ADO approvals) on any watched run ──
try {
    $awScript = Join-Path $PSScriptRoot 'Invoke-ApprovalWatch.ps1'
    if (Test-Path $awScript) {
        $verdict.ApprovalSideChannel = & $awScript -Action Sync `
            -ReleaseId $activeRelease.ReleaseId `
            -StateFile $activeRelease.StateFile `
            -StateLock (Join-Path $paths.ScratchDir 'state.json.lock') `
            -AuditFile $paths.AuditFile `
            -ReleaseFile $paths.ReleaseFile
        if (@($verdict.ApprovalSideChannel.NotifyEvents).Count -gt 0) {
            $state = Get-Content $activeRelease.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
} catch {
    $verdict.ApprovalSideChannel = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
}

# ── Step 3e: Revert bits side track (revertBits.prepareDuringCanaryBvt): PR → revert build → ready ──
try {
    $rbScript = Join-Path $PSScriptRoot 'Invoke-RevertBitsTrack.ps1'
    $rbPhase = if ($state.PSObject.Properties['revertBits'] -and $state.revertBits) { [string]$state.revertBits.phase } else { '' }
    if ((Test-Path $rbScript) -and $rbPhase -in @('pr-open', 'queue-build', 'building')) {
        $verdict.RevertBitsSideChannel = & $rbScript -Action Poll `
            -ReleaseId $activeRelease.ReleaseId `
            -StateFile $activeRelease.StateFile `
            -StateLock (Join-Path $paths.ScratchDir 'state.json.lock') `
            -AuditFile $paths.AuditFile `
            -ReleaseFile $paths.ReleaseFile
        if ($verdict.RevertBitsSideChannel.Transition) {
            $state = Get-Content $activeRelease.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
} catch {
    $verdict.RevertBitsSideChannel = [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
}

# ── Step 4: Determine current step ──
# Current step = lowest-numbered step whose status is neither 'completed' nor 'skipped'
$stepDeps = @{
    3 = @(2); 4 = @(2); 5 = @(3); 6 = @(5); 7 = @(6); 8 = @(7)
    9 = @(8); 10 = @(9); 11 = @(10); 12 = @(11); 13 = @(12, 4)
    14 = @(13); 15 = @(14); 16 = @(15)
}

$currentStep = $null
foreach ($step in ($state.steps | Sort-Object { $_.number })) {
    if ($step.status -in @('completed', 'skipped')) { continue }

    # Check if step's dependencies are satisfied
    $deps = $stepDeps[$step.number]
    $depsOk = $true
    if ($deps) {
        foreach ($depNum in $deps) {
            $depStep = $state.steps | Where-Object { $_.number -eq $depNum }
            if ($depStep -and $depStep.status -notin @('completed', 'skipped')) {
                $depsOk = $false
                break
            }
        }
    }

    # Step 4 parallel handling: if Step 4 is in-progress via side-channel and
    # we are looking at foreground steps, skip it (it advances independently)
    if ($step.number -eq 4 -and $step.status -eq 'in-progress' -and $state.step4InlineCompleted -eq $true) {
        continue  # Side-channel handles this; look for next foreground step
    }

    if ($depsOk) {
        $currentStep = $step
        break
    }
}

if (-not $currentStep) {
    # All steps done
    $verdict.Action = 'completed'
    $verdict.Message = "Release $($activeRelease.ReleaseId) — all steps completed"
    return $verdict
}

$verdict.CurrentStep = $currentStep.number
$verdict.StepName = $currentStep.name
$verdict.StepStatus = $currentStep.status

# ── Step 5: Evaluate step status and directive ──
switch ($currentStep.status) {
    'pending' {
        $verdict.Action = 'execute-step'
        $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) is pending — ready to execute"
    }
    'in-progress' {
        # Check if there's a watcher directive to evaluate
        $dir = $state.watcherDirective
        $verdict.WatcherDirective = $dir

        if (-not $dir -or $dir.action -eq 'none') {
            $verdict.Action = 'resume-step'
            $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) is in-progress with no active directive"
        } else {
            # Evaluate the directive condition
            $eval = [PSCustomObject]@{
                ConditionMet = $false
                Details      = $null
            }

            switch ($dir.action) {
                'wait-timer' {
                    $waitField = if ($dir.waitUntil) { $dir.waitUntil } elseif ($dir.scheduledAt) { $dir.scheduledAt } else { $null }
                    if ($waitField) {
                        $scheduled = [datetime]$waitField
                        $now = Get-Date
                        $eval.ConditionMet = ($now -ge $scheduled)
                        $eval.Details = "Timer: scheduled=$waitField, now=$($now.ToString('o')), met=$($eval.ConditionMet)"
                    }
                }
                'poll-ado-build' {
                    # Would need ADO API call — flag that evaluation is needed
                    $eval.Details = "ADO build poll — requires API evaluation at: $($dir.target)"
                    # In cloud mode, the session should evaluate this
                    $eval.ConditionMet = $null  # Signal: needs evaluation
                }
                'poll-ado-pr' {
                    $eval.Details = "RI/FI PR poll — requires API evaluation at: $($dir.target)"
                    $eval.ConditionMet = $null
                }
                'poll-ado-pipelines' {
                    # Check if any targets already have completion status from prior polling
                    if ($dir.targets) {
                        $allDone = $true
                        $anyFailed = $false
                        # waitForRunCompletion (serialization wait): only a real ADO 'completed' counts.
                        $waitForCompletion = $dir.PSObject.Properties['waitForRunCompletion'] -and $dir.waitForRunCompletion -eq $true
                        foreach ($t in $dir.targets) {
                            if ($waitForCompletion) {
                                if ($t.status -ne 'completed') { $allDone = $false }
                                continue
                            }
                            # 'deployed' = EV2 deployment done, run still in its managed validation (deploymentDoneWhen)
                            if ($t.status -notin @('completed', 'failed', 'deployed')) { $allDone = $false }
                            if ($t.status -eq 'failed') { $anyFailed = $true }
                        }
                        $eval.ConditionMet = $allDone
                        $eval.Details = "Pipeline poll: allDone=$allDone, anyFailed=$anyFailed"
                    } else {
                        $eval.Details = "Pipeline poll — requires API evaluation"
                        $eval.ConditionMet = $null
                    }
                }
                'poll-onedrive-file' {
                    $eval.Details = "OneDrive Excel poll — requires Graph API evaluation at: $($dir.target)"
                    $eval.ConditionMet = $null
                }
                'safefly-approval-poll' {
                    $eval.Details = "SafeFly approval poll — requires API evaluation for: $($dir.safeFlyId)"
                    $eval.ConditionMet = $null
                }
                'poll-ev2-rollout' {
                    $eval.Details = "EV2 rollout poll — requires API evaluation"
                    $eval.ConditionMet = $null
                }
                'poll-bvt-releases' {
                    # Invoke-BvtReleases.ps1 state for the BVT step; 'running' needs a live Poll.
                    $bvS = $null
                    if ($state.PSObject.Properties['bvtReleases'] -and $state.bvtReleases -and $state.bvtReleases.PSObject.Properties["$($dir.step)"]) { $bvS = $state.bvtReleases."$($dir.step)" }
                    $bvStatus = if ($bvS) { [string]$bvS.status } else { 'not-started' }
                    $eval.Details = "BVT releases for Step $($dir.step): $bvStatus"
                    # Reuse the catalog-aware evidence gate; do not trust cached completion.
                    $evidenceValid = $false
                    if ($bvStatus -eq 'completed') {
                        try {
                            $bv = & (Join-Path $PSScriptRoot 'Invoke-BvtReleases.ps1') -Action Get `
                                -ReleaseId $activeRelease.ReleaseId -Step ([int]$dir.step) `
                                -StateFile $activeRelease.StateFile -StateLock $paths.LockFile `
                                -AuditFile $paths.AuditFile -ReleaseFile $paths.ReleaseFile
                            $evidenceValid = $bv.Success -and $bv.Phase -eq 'completed'
                        } catch {
                            # Unreadable state/catalog: fail closed (live Poll needed), never crash cold resume.
                            $evidenceValid = $false
                        }
                        if (-not $evidenceValid) { $eval.Details += ' — BVT evidence not verified' }
                    }
                    $eval.ConditionMet = if ($bvStatus -eq 'completed' -and $evidenceValid) { $true } else { $null }
                }
                default {
                    $eval.Details = "Unknown directive action: $($dir.action)"
                }
            }

            $verdict.DirectiveEvaluation = $eval

            if ($eval.ConditionMet -eq $true) {
                $verdict.Action = 'execute-step'
                $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) — directive condition met, ready to continue"
            } elseif ($null -eq $eval.ConditionMet) {
                $verdict.Action = 'resume-step'
                $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) — directive needs live API evaluation"
            } else {
                $verdict.Action = 'wait'
                $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) — waiting on: $($dir.action)"
            }
        }
    }
    'waiting-approval' {
        $verdict.Action = 'approval-needed'
        $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) — waiting for approval"
    }
    { $_ -eq 'failed' -or $_ -like 'failed-*' } {
        $verdict.Action = 'failed'
        $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) — failed (status: $($currentStep.status))"
    }
    default {
        $verdict.Action = 'resume-step'
        $verdict.Message = "Step $($currentStep.number) ($($currentStep.name)) — status: $($currentStep.status)"
    }
}

return $verdict
