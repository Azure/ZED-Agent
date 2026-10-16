<#
.SYNOPSIS
    Executes Step 4 Phase B side-channel logic: polls the OneDrive Excel for Impact
    column fill percentage and handles the 24-hour nudge.

.DESCRIPTION
    This script is the shared implementation of the Step 4 side-channel poll. It is
    called by both:
      - Release-Watcher.ps1 (on every tick, as a non-fatal side-channel)
      - Invoke-ColdResume.ps1 (on every cloud wake-up, regardless of current step)

    The logic was originally embedded inline in Release-Watcher.ps1. Factoring it here
    ensures both execution modes (local watcher + cloud cold-resume) share identical
    behavior for Step 4 completion and the 24-hour nudge.

    Side-channel failures are ALWAYS non-fatal — callers should wrap in try/catch and
    continue regardless. The function returns a result object but never throws (it
    catches internally and returns error state).

.PARAMETER ReleaseId
    The release identifier.

.PARAMETER StateFile
    Full path to state.json.

.PARAMETER StateLock
    Full path to state.json.lock.

.PARAMETER AuditFile
    Full path to audit.jsonl.

.PARAMETER AccessToken
    Optional pre-acquired Graph API token. If not provided, attempts to acquire via az CLI.

.OUTPUTS
    PSCustomObject with: Success, ImpactPct, StepCompleted, NudgeSent, Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][string]$StateFile,
    [Parameter(Mandatory)][string]$StateLock,
    [Parameter(Mandatory)][string]$AuditFile,
    [string]$AccessToken,
    # Tracker mode only: service-config.json to pass to Invoke-CommitTracker (default: the skill's).
    [string]$ServiceConfigPath
)

$ErrorActionPreference = 'Stop'

# Dot-source state lock
$lockScript = Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1'
if (Test-Path $lockScript) { . $lockScript }

$result = [PSCustomObject]@{
    Success       = $false
    ImpactPct     = 0
    StepCompleted = $false
    NudgeSent     = $false
    Error         = $null
}

try {
    if (-not (Test-Path $StateFile)) {
        $result.Error = "State file not found: $StateFile"
        return $result
    }

    $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $step4 = $state.steps | Where-Object { $_.number -eq 4 }

    # Gate: only run if Step 4 Phase A is done and step is still in-progress
    if ($state.step4InlineCompleted -ne $true -or
        -not $step4 -or $step4.status -ne 'in-progress' -or
        -not $state.step4ExcelUrl) {
        $result.Success = $true  # Nothing to do — not an error
        return $result
    }

    # Tracker mode (commitExcel.mode == "tracker"): fill % comes from the release's sheet in the
    # shared workbook via Graph's Excel API (required columns, not just Impact).
    $tracker = if ($state.PSObject.Properties['step4Tracker']) { $state.step4Tracker } else { $null }
    if ($tracker -and $tracker.sheetName) {
        $tpArgs = @{ Action = 'Poll'; ReleaseId = $ReleaseId; SheetName = [string]$tracker.sheetName }
        if ($tracker.driveId) { $tpArgs.DriveId = [string]$tracker.driveId }
        if ($tracker.itemId) { $tpArgs.ItemId = [string]$tracker.itemId }
        if ($AccessToken) { $tpArgs.AccessToken = $AccessToken }
        if ($ServiceConfigPath) { $tpArgs.ServiceConfigPath = $ServiceConfigPath }
        $tp = & (Join-Path $PSScriptRoot 'Invoke-CommitTracker.ps1') @tpArgs
        if (-not $tp.Success) {
            $result.Error = "Commit tracker poll failed: $($tp.Error)"
            @{ ts = (Get-Date -Format 'o'); event = 'step4-side-channel-error'; error = $result.Error } |
                ConvertTo-Json -Compress | Add-Content $AuditFile -Encoding UTF8
            return $result
        }
        $total = $tp.TotalRows; $filled = $tp.Filled; $pct = $tp.Pct
    } else {
    # Acquire token if not provided
    if (-not $AccessToken) {
        $AccessToken = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv 2>$null
        if (-not $AccessToken) {
            $result.Error = "Failed to acquire Graph token for Step 4 side-channel"
            return $result
        }
    }

    # Download and analyze Excel
    $headers = @{ Authorization = "Bearer $AccessToken" }
    $tmpFile = Join-Path $env:TEMP "sidechannel_step4_excel_$ReleaseId.xlsx"
    Invoke-RestMethod -Uri $state.step4ExcelUrl -Headers $headers -OutFile $tmpFile -TimeoutSec 60 -ErrorAction Stop

    if (-not (Get-Module -ListAvailable ImportExcel)) {
        Install-Module ImportExcel -Scope CurrentUser -Force
    }
    $rows = Import-Excel $tmpFile -ErrorAction Stop
    $total = $rows.Count
    $filled = ($rows | Where-Object { $_.'Impact' -and $_.'Impact'.ToString().Trim() -ne '' }).Count
    $pct = if ($total -gt 0) { [math]::Round(($filled / $total) * 100) } else { 0 }
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    $result.ImpactPct = $pct

    # Audit the poll
    @{ ts = (Get-Date -Format 'o'); event = 'step4-side-channel-poll'; filled = $filled; total = $total; pct = $pct } |
        ConvertTo-Json -Compress | Add-Content $AuditFile -Encoding UTF8

    # Update state under lock
    Invoke-WithStateLock -LockFile $StateLock -Action {
        $latest = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $latest.PSObject.Properties['step4ExcelImpactPct']) {
            Add-Member -InputObject $latest -MemberType NoteProperty -Name step4ExcelImpactPct -Value $pct -Force
        } else {
            $latest.step4ExcelImpactPct = $pct
        }

        if ($pct -ge 100) {
            $s4 = $latest.steps | Where-Object { $_.number -eq 4 }
            if ($s4 -and $s4.status -eq 'in-progress') {
                $s4.status = 'completed'
                Add-Member -InputObject $s4 -MemberType NoteProperty -Name completedAt -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force
                @{ ts = (Get-Date -Format 'o'); event = 'step4-completed-by-side-channel'; pct = $pct } |
                    ConvertTo-Json -Compress | Add-Content $AuditFile -Encoding UTF8
                $result.StepCompleted = $true
            }
        }
        $latest.lastUpdated = (Get-Date).ToUniversalTime().ToString('o')
        $latest | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8 -NoNewline
    }

    # 24-hour nudge check
    if ($pct -lt 100 -and $state.step4InlineCompletedAt -and -not $state.step4NudgeSentAt) {
        $inlineCompletedAt = [datetime]$state.step4InlineCompletedAt
        if ((Get-Date) -gt $inlineCompletedAt.AddHours(24)) {
            try {
                $sendTeamsScript = Join-Path $PSScriptRoot 'Send-TeamsMessage.ps1'
                $nudgeTemplate  = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates/commit-nudge-message.html'
                if (Test-Path $sendTeamsScript) {
                    & $sendTeamsScript -TemplatePath $nudgeTemplate -TemplateVariables @{
                        releaseId = $ReleaseId; fillPct = $pct; excelUrl = $state.step4ExcelUrl
                    }
                }
                Invoke-WithStateLock -LockFile $StateLock -Action {
                    $latest = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (-not $latest.PSObject.Properties['step4NudgeSentAt']) {
                        Add-Member -InputObject $latest -MemberType NoteProperty -Name step4NudgeSentAt -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force
                    } else {
                        $latest.step4NudgeSentAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    $latest | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8 -NoNewline
                }
                $result.NudgeSent = $true
            } catch {
                @{ ts = (Get-Date -Format 'o'); event = 'step4-nudge-error'; error = $_.Exception.Message } |
                    ConvertTo-Json -Compress | Add-Content $AuditFile -Encoding UTF8
            }
        }
    }

    $result.Success = $true
} catch {
    $result.Error = $_.Exception.Message
    try {
        @{ ts = (Get-Date -Format 'o'); event = 'step4-side-channel-error'; error = $_.Exception.Message } |
            ConvertTo-Json -Compress | Add-Content $AuditFile -Encoding UTF8
    } catch { <# audit write is best-effort #> }
}

return $result
