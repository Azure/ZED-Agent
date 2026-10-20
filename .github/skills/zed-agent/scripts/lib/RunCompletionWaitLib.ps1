<#
.SYNOPSIS
    Serialization wait for `poll-ado-pipelines` directives with `waitForRunCompletion: true`.

.DESCRIPTION
    Used before triggering a deployment while other runs of the same EV2 service group are
    still running (EV2 runs one rollout per service group at a time — step-behaviors.md →
    "EV2 deployment done → Before triggering Steps 7, 10, 13, 15").

    A target is done ONLY when its ADO run reports status 'completed' (any result):
      * the catalog `deploymentDoneWhen` 'deployed' shortcut is NOT applied (BCM-CANARY is
        "deployed" long before its run — and its EV2 rollout — finishes; using the shortcut
        here completed the wait at once and re-invoked the agent in a loop);
      * a completed run with a failed result is NOT a failure of this release (it may be
        another release's or a manual run) — it is recorded (`result`) and the wait completes.

    Each checked target gets adoStatus / checkedAt (and result / finishTime when completed),
    which the watcher writes back to state.json.

.OUTPUTS
    PSCustomObject { AllDone: bool; Completed: object[] (targets that completed in this call) }
#>

function Update-RunCompletionTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Targets,
        # { param($Target) → ADO build object (status, result, finishTime, id) }
        [Parameter(Mandatory)][scriptblock] $GetRun
    )
    $allDone = $true
    $completedNow = @()
    if (@($Targets).Count -eq 0) { return [pscustomobject]@{ AllDone = $false; Completed = @() } }
    foreach ($t in $Targets) {
        if ("$($t.status)" -eq 'completed') { continue }
        $run = & $GetRun $t
        $t | Add-Member -NotePropertyName adoStatus -NotePropertyValue "$($run.status)" -Force
        $t | Add-Member -NotePropertyName checkedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        if ("$($run.status)" -eq 'completed') {
            $t | Add-Member -NotePropertyName status -NotePropertyValue 'completed' -Force
            $t | Add-Member -NotePropertyName result -NotePropertyValue "$($run.result)" -Force
            $t | Add-Member -NotePropertyName finishTime -NotePropertyValue "$($run.finishTime)" -Force
            $completedNow += $t
        } else {
            $allDone = $false
        }
    }
    return [pscustomobject]@{ AllDone = $allDone; Completed = @($completedNow) }
}
