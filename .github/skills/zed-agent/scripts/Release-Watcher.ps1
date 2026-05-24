param([Parameter(Mandatory)][string]$ReleaseId)
$ErrorActionPreference = 'Stop'
$stateFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/state.json"
$lockFile  = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/watcher.lock"
$stateLock = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/state.json.lock"

. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

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
    # Implements the Step Dependency Matrix parallelism contract (Step 3 ∥ Step 4)
    # without requiring a multi-directive watcher. If Step 4's inline (Phase A)
    # work has completed and the Excel Impact column is still being filled,
    # opportunistically poll the OneDrive file on every tick — regardless of
    # which step owns the primary directive (typically poll-ado-build during
    # Step 3, poll-ado-pipelines during Step 5, etc.). Failures here are
    # non-fatal — the primary directive polling continues unaffected.
    # ─────────────────────────────────────────────────────────────────────────
    try {
        $step4 = $state.steps | Where-Object { $_.number -eq 4 }
        if ($state.step4InlineCompleted -eq $true `
            -and $step4 -and $step4.status -eq 'in-progress' `
            -and $state.step4ExcelUrl) {
            $tokenS4 = Get-AzToken "https://graph.microsoft.com"
            if ($tokenS4) {
                $hdrS4 = @{ Authorization = "Bearer $tokenS4" }
                $tmpS4 = Join-Path $env:TEMP "watcher_step4_excel_$ReleaseId.xlsx"
                Invoke-RestMethod -Uri $state.step4ExcelUrl -Headers $hdrS4 -OutFile $tmpS4 -TimeoutSec 60 -ErrorAction Stop
                if (-not (Get-Module -ListAvailable ImportExcel)) { Install-Module ImportExcel -Scope CurrentUser -Force }
                $rowsS4 = Import-Excel $tmpS4 -ErrorAction Stop
                $totalS4 = $rowsS4.Count
                $filledS4 = ($rowsS4 | Where-Object { $_.'Impact' -and $_.'Impact'.ToString().Trim() -ne '' }).Count
                $pctS4 = if ($totalS4 -gt 0) { [math]::Round(($filledS4 / $totalS4) * 100) } else { 0 }
                Remove-Item $tmpS4 -Force -ErrorAction SilentlyContinue

                $auditFileS4 = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
                @{ ts = (Get-Date -Format 'o'); event = 'step4-side-channel-poll'; filled = $filledS4; total = $totalS4; pct = $pctS4 } | ConvertTo-Json -Compress | Add-Content $auditFileS4 -Encoding UTF8

                Invoke-WithStateLock -LockFile $stateLock -Action {
                    $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $latest.step4ExcelImpactPct = $pctS4
                    if ($pctS4 -ge 100) {
                        $s4 = $latest.steps | Where-Object { $_.number -eq 4 }
                        if ($s4 -and $s4.status -eq 'in-progress') {
                            $s4.status = 'completed'
                            $s4.completedAt = (Get-Date).ToUniversalTime().ToString('o')
                            @{ ts = (Get-Date -Format 'o'); event = 'step4-completed-by-side-channel'; pct = $pctS4 } | ConvertTo-Json -Compress | Add-Content $auditFileS4 -Encoding UTF8
                        }
                    }
                    $latest.lastUpdated = (Get-Date).ToUniversalTime().ToString('o')
                    $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
                }

                # 24h nudge if no progress
                if ($pctS4 -lt 100 -and $state.step4InlineCompletedAt -and -not $state.step4NudgeSentAt) {
                    $inlineCompletedAt = [datetime]$state.step4InlineCompletedAt
                    if ((Get-Date) -gt $inlineCompletedAt.AddHours(24)) {
                        try {
                            $sendTeamsScript = Join-Path (Get-Location) ".github/skills/zed-agent/scripts/Send-TeamsMessage.ps1"
                            $nudgeTemplate = Join-Path (Get-Location) ".github/skills/zed-agent/templates/commit-nudge-message.html"
                            & $sendTeamsScript -TemplatePath $nudgeTemplate -TemplateVariables @{ releaseId = $ReleaseId; fillPct = $pctS4; excelUrl = $state.step4ExcelUrl }
                            Invoke-WithStateLock -LockFile $stateLock -Action {
                                $latest = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                                $latest.step4NudgeSentAt = (Get-Date).ToUniversalTime().ToString('o')
                                $latest | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
                            }
                        } catch {
                            @{ ts = (Get-Date -Format 'o'); event = 'step4-nudge-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFileS4 -Encoding UTF8
                        }
                    }
                }
            }
        }
    } catch {
        # Side-channel failure is non-fatal — primary directive polling continues
        $auditFileS4Err = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
        @{ ts = (Get-Date -Format 'o'); event = 'step4-side-channel-error'; error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content $auditFileS4Err -Encoding UTF8
    }

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
            foreach ($t in $dir.targets) {
                if ($t.status -in @('completed','failed')) { continue }
                $resp = Invoke-RestMethod -Uri $t.url -Headers $headers -TimeoutSec 60 -ErrorAction Stop
                if ($resp.status -eq 'completed') {
                    $t.status = if ($resp.result -eq 'succeeded') { 'completed' } else { 'failed' }
                }
                if ($t.status -eq 'failed') { $anyFailed = $true }
                if ($t.status -notin @('completed','failed')) { $allDone = $false }
            }

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
                                $vars = @{
                                    releaseId = $ReleaseId; buildVersion = $release.buildVersion; branch = $release.branch
                                    approvalRows = ($newRows -join "`n"); ev2Links = ($newEv2Links -join "`n")
                                    releaseOwner = if ($release.releaseOwner) { $release.releaseOwner } else { 'Release Owner' }
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
        if (Test-Path $stateFile) {
            try {
                $peek = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($peek.status -in @('completed','stopped')) { $remaining = 0 }
            } catch { <# transient read race — keep sleeping #> }
        }
    }
}
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
