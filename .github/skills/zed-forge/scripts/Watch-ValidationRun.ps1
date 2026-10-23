<#
.SYNOPSIS
    Poll a ZED true test run in the target repo until it reaches a terminal
    state (or times out), then return a summary the verifier can consume.

.DESCRIPTION
    The true test run is synchronous (no watcher), but ZedForge may launch it
    detached / in a separate process. This poller watches
    <target>/.zed-agent/releases/<id>/state.json and decides "terminal" when:
      - state.status is completed / failed / stopped, OR
      - every non-skipped step is completed, OR
      - any non-skipped step is failed / failed-drift,
    and otherwise sleeps until the timeout. It tolerates the state file not
    existing yet (run still initialising).

.PARAMETER TargetRepo   Target deployment repo.
.PARAMETER ReleaseId    Test release id (e.g., TEST-2026-07).
.PARAMETER TimeoutMinutes  Default 30.
.PARAMETER PollIntervalSeconds  Default 15.
.PARAMETER NonSkippedSteps  Steps that must complete. Default 1,2,4,5,6,10,13.
.OUTPUTS PSCustomObject { terminal, timedOut, status, steps, failedSteps, capturePath, statePath }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRepo,
    [Parameter(Mandatory)][string]$ReleaseId,
    [int]$TimeoutMinutes = 30,
    [int]$PollIntervalSeconds = 15,
    [int[]]$NonSkippedSteps = @(1, 2, 4, 5, 6, 10, 13)
)

$ErrorActionPreference = 'Stop'
$relDir    = Join-Path $TargetRepo ".zed-agent/releases/$ReleaseId"
$stateFile = Join-Path $relDir 'state.json'
$capture   = Join-Path $relDir 'test-run-capture.json'

# Handle both state.steps shapes: array of {number,status} OR object { "N": {status} }.
function Get-StepStatusMap($state) {
    $map = @{}
    if (-not $state.PSObject.Properties['steps']) { return $map }
    $steps = $state.steps
    if ($steps -is [System.Array]) {
        foreach ($s in $steps) { if ($s.PSObject.Properties['number']) { $map["$($s.number)"] = $s.status } }
    }
    else {
        foreach ($p in $steps.PSObject.Properties) { $map[$p.Name] = $p.Value.status }
    }
    return $map
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$terminal = $false
$timedOut = $false
$status   = 'unknown'
$stepMap  = @{}
$failed   = @()

while ($true) {
    if (Test-Path $stateFile) {
        try {
            $state  = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $status = if ($state.PSObject.Properties['status']) { $state.status } else { 'unknown' }
            $stepMap = Get-StepStatusMap $state

            if ($status -in @('completed', 'failed', 'stopped')) { $terminal = $true }

            $failed = @($NonSkippedSteps | Where-Object { $stepMap["$_"] -in @('failed', 'failed-drift') })
            if ($failed.Count -gt 0) { $terminal = $true }

            $allDone = $true
            foreach ($n in $NonSkippedSteps) {
                if ($stepMap["$n"] -ne 'completed') { $allDone = $false; break }
            }
            if ($allDone) { $terminal = $true }
        }
        catch { <# transient partial write; retry next tick #> }
    }

    if ($terminal) { break }
    if ((Get-Date) -ge $deadline) { $timedOut = $true; break }
    Start-Sleep -Seconds $PollIntervalSeconds
}

$capturePathVal = if (Test-Path $capture) { $capture } else { $null }
$statePathVal   = if (Test-Path $stateFile) { $stateFile } else { $null }

return [pscustomobject]@{
    terminal    = $terminal
    timedOut    = $timedOut
    status      = $status
    steps       = $stepMap
    failedSteps = $failed
    capturePath = $capturePathVal
    statePath   = $statePathVal
    releaseId   = $ReleaseId
    targetRepo  = $TargetRepo
}
