param([Parameter(Mandatory)][string]$ReleaseId)
$ErrorActionPreference = 'Stop'
$stateFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/state.json"
$lockFile  = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/watcher.lock"

# Write lock file with PID
@{ pid = $PID; startedAt = (Get-Date -Format 'o') } | ConvertTo-Json | Set-Content $lockFile -Encoding UTF8

$retryCount = 0; $maxRetries = 3; $baseDelay = 30
$authFailNotified = $false

function Get-AzToken([string]$Resource) {
    # Returns token string or $null on auth error (caller decides how to handle)
    $raw = az account get-access-token --resource $Resource --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = "$raw"
        if ($msg -match 'AADSTS|invalid_resource|Status_IncorrectConfiguration|InteractionRequired') {
            return $null  # Auth error — recoverable, don't throw
        }
        throw "az token error: $msg"  # Non-auth error — let caller's catch handle it
    }
    return $raw
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
    $dir = $state.watcherDirective
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
                $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
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
                $resp = Invoke-RestMethod -Uri $t.url -Headers $headers -ErrorAction Stop
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
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
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
            Invoke-RestMethod -Uri $dir.target -Headers $headers -OutFile $tempFile -ErrorAction Stop
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
            $state.ev2Diagnostics = $allResults
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline

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
        # Single-target polling (poll-ado-build, poll-ado-pipeline, poll-onedrive-file)
        try {
            $resource = if ($dir.action -match 'onedrive') { "https://graph.microsoft.com" } else { "https://dev.azure.com" }
            $token = Get-AzToken $resource
            if (-not $token) {
                if (-not $authFailNotified) { Write-AuthFailureAudit $ReleaseId $dir.action; $authFailNotified = $true }
                Start-Sleep -Seconds 300; continue
            }
            $authFailNotified = $false
            $headers = @{ Authorization = "Bearer $token" }
            $resp = Invoke-RestMethod -Uri $dir.target -Headers $headers -ErrorAction Stop
            if ($dir.successCondition -match '^\$\.(\w+)\s*==\s*''(.+)''$') {
                $conditionMet = ($resp.$($Matches[1]) -eq $Matches[2])
            } elseif ($dir.successCondition -match '^\$\.(\w+)\s*>\s*''(.+)''$') {
                $conditionMet = ($resp.$($Matches[1]) -gt $Matches[2])
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
    # Test mode: cap poll interval at 30 minutes for faster iteration
    try {
        $releaseFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/release.json"
        if (Test-Path $releaseFile) {
            $release = Get-Content $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($release.testMode -eq $true) { $interval = [math]::Min($interval, 1800) }
        }
    } catch { <# Ignore — use default interval on parse failure #> }
    Start-Sleep -Seconds $interval
}
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
