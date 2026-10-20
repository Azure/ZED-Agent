<#
.SYNOPSIS
    Approval requests side-channel: finds ZED-triggered deployment runs that are stuck waiting for
    an approval, and produces ready-to-send email/Teams messages with the approval link —
    a first notice, reminders every operational.approvalReminderHours while still pending, an
    "expires soon" alert before the approval task expires, and a notice when the approval task
    ends without approval.

.DESCRIPTION
    Watched runs (in-progress ADO pipeline runs) come from state.json / release.json:
      triggeredPipelines.<N> (any step key: '5', 'step5', '7', '10', '15'; ids or {runId|buildId|id}),
      watcherDirective.targets[].buildId, privateStampUpgrade.runs.(last|current).runId.

    Two kinds of approval wait are detected in each run's timeline:
      approval-service  OneBranch "Approval service" server task (job 'ApprovalService') still
                        running. The link comes from its 'Waiting for Approval' log:
                        https://approval.azengsys.com/approvalRequest?id=… plus "Approval Task will
                        expire on <UTC>". Stages that share one approval request (e.g. PROD/FF/MC)
                        are reported as one request.
      ado-approval      An ADO environment approval check (timeline type 'Checkpoint.Approval') in
                        progress — approved in the ADO run page.
    Other checks (e.g. Checkpoint.ProductionReadinessCheck) are not approvals and are ignored.

    State: state.approvalRequests.<id> (id = 8-hex hash of the approval key) =
      { id, key, kind, url, runId, runUrl, pipelineId, pipelineName, runName, step, stages[],
        waitingSince, expiresAt, status (pending|approved|ended), firstSeenAt, lastNotifiedAt,
        notifyCount, expiryWarnedAt, endedResult, lastMessage { event, eventKey, subject, html } }
    state.approvalWatch = { lastSyncAt, doneRuns[] }

    Actions
      Sync  Scan, update state, return NotifyEvents [{ event, id, eventKey }]; each has its rendered
            message in state.approvalRequests.<id>.lastMessage. Never throws (errors in .Error).
            Events: approval-needed | approval-reminder | approval-expiring | approval-failed.
      Get   Return state.approvalRequests.
.OUTPUTS
    PSCustomObject: Success, Action, NotifyEvents[], Pending[], Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Sync', 'Get')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$StateFile,
    [string]$StateLock,
    [string]$AuditFile,
    [string]$ReleaseFile,
    [string]$ServiceConfigPath,
    [string]$TemplatePath,
    [string]$Organization,
    [string]$Project,
    [string]$AccessToken,
    [double]$ReminderHours = -1,
    [double]$ExpiryWarnHours = -1,
    [datetime]$Now = [datetime]::MinValue
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')
. (Join-Path $PSScriptRoot 'Expand-Template.ps1')

$out = [pscustomobject]@{ Success = $false; Action = $Action; NotifyEvents = @(); Pending = @(); Error = $null }
$script:ApprovalUrlRx = 'https://approval\.azengsys\.com/approvalRequest\?id=[A-Fa-f0-9]+'
$script:ExpiryRx = '(?i)will expire on\s+(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}Z?)'

function Get-UtcNow { if ($script:NowOverride -ne [datetime]::MinValue) { return $script:NowOverride.ToUniversalTime() } (Get-Date).ToUniversalTime() }
function Get-NowIso { (Get-UtcNow).ToString('o') }

function Write-Audit([hashtable]$Entry) {
    try { $Entry.ts = Get-NowIso; $Entry | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $script:AuditFile -Encoding UTF8 } catch { }
}

function Get-AdoToken {
    if ($script:AccessToken) { return $script:AccessToken }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $t = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null } finally { $ErrorActionPreference = $prev }
    if (-not $t) { throw "Failed to acquire ADO token. Run 'az login --tenant microsoft.com'." }
    $script:AccessToken = $t
    return $t
}

function Invoke-AdoGet([string]$Path, [switch]$Text) {
    $h = @{ Authorization = "Bearer $(Get-AdoToken)" }
    $uri = "https://dev.azure.com/$($script:Org)/$($script:Proj)/_apis/$Path"
    if ($Text) { return [string](Invoke-WebRequest -Uri $uri -Headers $h -UseBasicParsing -ErrorAction Stop).Content }
    return Invoke-RestMethod -Uri $uri -Headers $h -ErrorAction Stop
}

# ADO timestamps are UTC; Invoke-RestMethod can return them as DateTime with Kind 'Unspecified',
# which ToUniversalTime() would wrongly shift by the local offset. Normalise everything here.
function ConvertTo-UtcDate($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }
        return $v.ToUniversalTime()
    }
    return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}
function ConvertTo-UtcIso($v) { $d = ConvertTo-UtcDate $v; if ($d) { return $d.ToString('yyyy-MM-ddTHH:mm:ssZ') } return $null }

function Get-ShortId([string]$Key) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key))).Replace('-', '').Substring(0, 8).ToLowerInvariant()
}

function Get-StepFromKey([string]$k) {
    if ($k -match '^(?i)(?:step)?(\d{1,2})$') { return [int]$Matches[1] }
    return $null
}

function Get-RunIdFromValue($v) {
    if ($null -eq $v) { return $null }
    if ("$v" -match '^\d+$') { return [long]"$v" }
    foreach ($n in 'runId', 'buildId', 'id') {
        $p = $v.PSObject.Properties[$n]
        if ($p -and "$($p.Value)" -match '^\d+$') { return [long]"$($p.Value)" }
    }
    return $null
}

# runId -> step label source ('5', '15', 'private-stamp', ...)
function Get-WatchedRuns($State, $Release) {
    $runs = [ordered]@{}
    foreach ($src in @($State, $Release)) {
        if ($null -eq $src) { continue }
        $tp = $src.PSObject.Properties['triggeredPipelines']
        if (-not ($tp -and $tp.Value)) { continue }
        foreach ($p in $tp.Value.PSObject.Properties) {
            $step = Get-StepFromKey $p.Name
            foreach ($v in @($p.Value)) {
                $id = Get-RunIdFromValue $v
                if ($id -and -not $runs.Contains($id)) { $runs[$id] = $(if ($step) { "$step" } else { $null }) }
            }
        }
    }
    $dir = if ($State.PSObject.Properties['watcherDirective']) { $State.watcherDirective } else { $null }
    if ($dir -and $dir.PSObject.Properties['targets']) {
        foreach ($t in @($dir.targets)) {
            $id = Get-RunIdFromValue $t
            if ($id -and -not $runs.Contains($id)) { $runs[$id] = $(if ($State.PSObject.Properties['currentStep']) { "$($State.currentStep)" } else { $null }) }
        }
    }
    if ($State.PSObject.Properties['privateStampUpgrade'] -and $State.privateStampUpgrade -and $State.privateStampUpgrade.runs) {
        foreach ($leg in @('last', 'current')) {
            $r = $State.privateStampUpgrade.runs.PSObject.Properties[$leg]
            if ($r -and $r.Value) { $id = Get-RunIdFromValue $r.Value; if ($id -and -not $runs.Contains($id)) { $runs[$id] = 'private-stamp' } }
        }
    }
    return $runs
}

function Get-StepLabel($Step) {
    switch ("$Step") {
        '5' { 'Step 5 · Canary deployment' }
        '7' { 'Step 7 · Canary rollback' }
        '10' { 'Step 10 · Roll-forward (production pipelines → canary regions)' }
        '15' { 'Step 15 · Production rollout' }
        'private-stamp' { 'Private stamp upgrade test' }
        '' { 'Deployment' }
        default { "Step $Step" }
    }
}

function ConvertTo-Friendly([string]$Iso) {
    if (-not $Iso) { return '' }
    try { $d = ConvertTo-UtcDate $Iso; return "$($d.ToString('yyyy-MM-dd HH:mm')) UTC ($($d.AddMinutes(330).ToString('dd MMM HH:mm')) IST)" } catch { return $Iso }
}

# Pending approvals in one run: @{ <key> = @{ kind; url; stages[]; waitingSince; expiresAt } } and
# ended approval-service tasks: @{ <url> = <result> }
function Find-Approvals([long]$RunId) {
    $tl = Invoke-AdoGet "build/builds/$RunId/timeline?api-version=7.1"
    $recs = @($tl.records)
    $byId = @{}; foreach ($r in $recs) { if ($r.id) { $byId[$r.id] = $r } }
    function Get-Stage($id) {
        $seen = @{}; $cur = $id
        while ($cur -and $byId.ContainsKey($cur) -and -not $seen.ContainsKey($cur)) {
            $seen[$cur] = 1; $rec = $byId[$cur]
            if ($rec.type -eq 'Stage') { return $rec }
            $cur = $rec.parentId
        }
        return $null
    }
    $pending = [ordered]@{}; $ended = @{}
    $logCache = @{}
    foreach ($task in @($recs | Where-Object { $_.type -eq 'Task' -and $_.name -match '^(?i)approval service$' })) {
        $job = $task.parentId
        $stage = Get-Stage $job
        $stageName = if ($stage) { [string]$stage.name } elseif ($byId.ContainsKey($job)) { [string]$byId[$job].name } else { 'ApprovalService' }
        $url = $null; $exp = $null
        $logRecs = @($recs | Where-Object { $_.parentId -eq $job -and $_.log -and $_.log.id -and ($_.name -match '(?i)waiting for approval|request approved' -or $_.id -eq $task.id) })
        foreach ($lr in $logRecs) {
            $lid = [int]$lr.log.id
            if (-not $logCache.ContainsKey($lid)) { try { $logCache[$lid] = Invoke-AdoGet "build/builds/$RunId/logs/$($lid)?api-version=7.1" -Text } catch { $logCache[$lid] = ''; Write-Audit @{ event = 'approval-watch-log-error'; runId = $RunId; logId = $lid; error = $_.Exception.Message } } }
            $txt = $logCache[$lid]
            if (-not $url) { $m = [regex]::Match($txt, $script:ApprovalUrlRx); if ($m.Success) { $url = $m.Value } }
            if (-not $exp) { $m = [regex]::Match($txt, $script:ExpiryRx); if ($m.Success) { try { $exp = ConvertTo-UtcIso ($m.Groups[1].Value.TrimEnd('Z')) } catch { } } }
        }
        $isPending = ($task.state -in @('inProgress', 'pending')) -and -not $task.result
        if ($isPending) {
            if (-not $url) { continue }   # link not logged yet — next tick
            # A waiting Approval service task often has no startTime (state 'pending'); its
            # 'Waiting for Approval' sub-record carries the real start.
            $since = $task.startTime
            if (-not $since) { $since = ConvertTo-UtcIso (@($logRecs | Where-Object { $_.startTime } | Sort-Object { ConvertTo-UtcDate $_.startTime } | Select-Object -First 1).startTime) }
            if (-not $since -and $stage) { $since = ConvertTo-UtcIso $stage.startTime }
            if (-not $pending.Contains($url)) { $pending[$url] = @{ kind = 'approval-service'; url = $url; stages = @(); waitingSince = $since; expiresAt = $exp } }
            if ($pending[$url].stages -notcontains $stageName) { $pending[$url].stages += $stageName }
            if ($since -and (-not $pending[$url].waitingSince -or (ConvertTo-UtcDate $since) -lt (ConvertTo-UtcDate $pending[$url].waitingSince))) { $pending[$url].waitingSince = $since }
        } elseif ($url -and $task.result) {
            if (-not $ended.ContainsKey($url) -or $task.result -ne 'succeeded') { $ended[$url] = [string]$task.result }
        }
    }
    foreach ($cp in @($recs | Where-Object { $_.type -eq 'Checkpoint.Approval' })) {
        $key = "ado:$($RunId):$($cp.id)"
        if ($cp.state -in @('inProgress', 'pending') -and -not $cp.result) {
            $stage = Get-Stage $cp.parentId
            $pending[$key] = @{ kind = 'ado-approval'; url = $null; stages = @($(if ($stage) { [string]$stage.name } else { 'Approval check' })); waitingSince = (ConvertTo-UtcIso $cp.startTime); expiresAt = $null }
        } elseif ($cp.result) { $ended[$key] = [string]$cp.result }
    }
    return @{ pending = $pending; ended = $ended }
}

function Get-PreTriggerHold($Req) {
    $st = $script:StateForMessage
    if (-not $st -or -not $st.PSObject.Properties['productionPreTrigger'] -or -not $st.productionPreTrigger) { return $null }
    $hit = @($st.productionPreTrigger.runs | Where-Object { $_ -and [long]$_.runId -eq [long]$Req.runId })
    if (-not $hit.Count) { return $null }
    $s14 = @($st.steps | Where-Object { $_.number -eq 14 }) | Select-Object -First 1
    if ($s14 -and $s14.status -in @('completed', 'skipped')) { return $null }
    $txt = 'This production run was triggered at Step 13 only to obtain the build number for the SafeFly R2D. Approve it only after Step 14 (SafeFly R2D approval + CRB) is complete and the release owner'
    $txt += $(if ($st.releaseOwner) { " ($([System.Net.WebUtility]::HtmlEncode([string]$st.releaseOwner)))" } else { '' })
    $txt += ' confirms.'
    if ($st.PSObject.Properties['ev2SerializationOverride'] -and $st.ev2SerializationOverride -and $st.ev2SerializationOverride.inProgressRunOverridden) {
        $o = $st.ev2SerializationOverride.inProgressRunOverridden
        $txt += " Also wait until $([System.Net.WebUtility]::HtmlEncode([string]$o.pipeline)) run $([long]$o.runId) ($([System.Net.WebUtility]::HtmlEncode([string]$o.buildNumber))) has completed: its EV2 rollouts are still active and EV2 allows one rollout per service group."
    }
    return $txt
}

function New-Message($Req, [string]$Event, $Release) {
    $now = Get-UtcNow
    $waitedH = if ($Req.waitingSince) { [math]::Round(($now - (ConvertTo-UtcDate $Req.waitingSince)).TotalHours, 1) } else { $null }
    $expH = if ($Req.expiresAt) { [math]::Round(((ConvertTo-UtcDate $Req.expiresAt) - $now).TotalHours, 1) } else { $null }
    switch ($Event) {
        'approval-needed'   { $headline = '🔐 Approval needed'; $note = 'The deployment is paused until this approval is given.' }
        'approval-reminder' { $headline = "⏰ Reminder #$([math]::Max(1, [int]$Req.notifyCount - 1)): approval still pending"; $note = "Still waiting after $waitedH h." }
        'approval-expiring' { $headline = '⚠️ Approval expires soon'; $note = "The approval task expires in $expH h. After that the stage must be restarted before it can be approved." }
        'approval-failed'   { $headline = "❌ Approval task ended ($($Req.endedResult))"; $note = 'The approval was not given (rejected or expired). Restart the stage in the run below, then approve the new request.' }
    }
    $isAdo = $Req.kind -eq 'ado-approval'
    $approveUrl = if ($isAdo) { [string]$Req.runUrl } else { [string]$Req.url }
    $scope = ''
    try {
        . (Join-Path $PSScriptRoot 'Get-ScopeTemplateVars.ps1')
        $sv = Get-ScopeTemplateVars -ReleaseId $script:ReleaseIdValue
        if ($sv -and "$($sv.routeCount)" -match '^\d+$') { $scope = "$($sv.routeCount) route(s) covering $($sv.geographyCount) geograph(ies)" }
    } catch { }
    $vars = @{
        headline     = $headline
        note         = $note
        serviceName  = $script:ServiceName
        releaseId    = $script:ReleaseIdValue
        stepLabel    = (Get-StepLabel $Req.step)
        pipelineName = [System.Net.WebUtility]::HtmlEncode([string]$Req.pipelineName)
        runName      = [System.Net.WebUtility]::HtmlEncode([string]$Req.runName)
        runUrl       = [string]$Req.runUrl
        stages       = [System.Net.WebUtility]::HtmlEncode((@($Req.stages) -join ', '))
        approveUrl   = $approveUrl
        approveLabel = $(if ($isAdo) { 'Approve in Azure DevOps (Review → Approve)' } elseif ($Event -eq 'approval-failed') { 'Open the approval request' } else { 'Approve the release' })
        waitingSince = (ConvertTo-Friendly $Req.waitingSince)
        expiresAt    = (ConvertTo-Friendly $Req.expiresAt)
        scope        = $scope
        releaseOwner = $(if ($Release -and $Release.releaseOwner) { "$($Release.releaseOwner.alias)" } else { '' })
    }
    $html = Expand-Template -TemplatePath $script:Template -Variables $vars
    $subject = "$headline — $($Req.pipelineName) | $($script:ServiceName) $($script:ReleaseIdValue)"
    # Step 13 pre-trigger hold (safefly.r2dBuildSource = productionRun): the production run exists before
    # the R2D is approved; step-behaviors Step 13 requires every message to say it MUST NOT be approved
    # before Step 14 (SafeFly + CRB) completes. Also name any run the owner overrode EV2 serialization for.
    $hold = Get-PreTriggerHold $Req
    if ($hold -and $Event -ne 'approval-failed') {
        $html = "<div style=`"border:2px solid #c50f1f; background:#fde7e9; padding:8px; font-family:Segoe UI,Arial,sans-serif;`"><b>⛔ DO NOT APPROVE YET.</b> $hold</div><br>" + $html
        $subject = "⛔ HOLD — do not approve yet — $subject"
    }
    $eventKey = if ($Event -eq 'approval-failed') { 'approval-failed' } else { $Event }
    return [pscustomobject]@{ event = $Event; eventKey = $eventKey; subject = $subject; html = $html; at = (Get-NowIso) }
}

try {
    $script:NowOverride = $Now
    $script:ReleaseIdValue = $ReleaseId
    if (-not $StateFile -or -not $StateLock -or -not $AuditFile -or -not $ReleaseFile) {
        $paths = & (Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1') -ReleaseId $ReleaseId
        if (-not $StateFile) { $StateFile = $paths.StateFile }
        if (-not $StateLock) { $StateLock = $paths.LockFile }
        if (-not $AuditFile) { $AuditFile = $paths.AuditFile }
        if (-not $ReleaseFile) { $ReleaseFile = $paths.ReleaseFile }
    }
    $script:AuditFile = $AuditFile; $script:AccessToken = $AccessToken
    if (-not $TemplatePath) { $TemplatePath = Join-Path $PSScriptRoot '..\templates\approval-service-request.html' }
    $script:Template = $TemplatePath
    if (-not (Test-Path -LiteralPath $StateFile)) { throw "State file not found: $StateFile" }
    $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:StateForMessage = $state
    $release = if (Test-Path -LiteralPath $ReleaseFile) { Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

    if ($Action -eq 'Get') {
        $out.Pending = if ($state.PSObject.Properties['approvalRequests'] -and $state.approvalRequests) { @($state.approvalRequests.PSObject.Properties.Value | Where-Object { $_.status -eq 'pending' }) } else { @() }
        $out.Success = $true
        return $out
    }
    if ($release -and $release.PSObject.Properties['testMode'] -and $release.testMode -eq $true) { $out.Success = $true; return $out }

    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    $svc = if (Test-Path -LiteralPath $ServiceConfigPath) { Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $script:Org = if ($Organization) { $Organization } elseif ($svc) { $svc.ado.organization } else { 'msazure' }
    $script:Proj = if ($Project) { $Project } elseif ($svc) { $svc.ado.project } else { 'One' }
    $script:ServiceName = if ($svc -and $svc.service.displayName) { [string]$svc.service.displayName } else { 'Service' }
    $op = if ($svc -and $svc.PSObject.Properties['operational']) { $svc.operational } else { $null }
    if ($ReminderHours -lt 0) { $ReminderHours = if ($op -and $op.PSObject.Properties['approvalReminderHours']) { [double]$op.approvalReminderHours } else { 4 } }
    if ($ExpiryWarnHours -lt 0) { $ExpiryWarnHours = if ($op -and $op.PSObject.Properties['approvalExpiryWarnHours']) { [double]$op.approvalExpiryWarnHours } else { 12 } }

    $runs = Get-WatchedRuns $state $release
    $done = @{}
    if ($state.PSObject.Properties['approvalWatch'] -and $state.approvalWatch -and $state.approvalWatch.doneRuns) { foreach ($d in @($state.approvalWatch.doneRuns)) { $done[[long]$d] = $true } }
    $existing = @{}
    if ($state.PSObject.Properties['approvalRequests'] -and $state.approvalRequests) { foreach ($p in $state.approvalRequests.PSObject.Properties) { $existing[$p.Name] = $p.Value } }

    $found = @{}          # id -> scan data (pending now)
    $endedByKey = @{}     # approval key -> result
    $scanned = @{}        # runId -> $true (timeline read OK)
    $newlyDone = @()
    foreach ($runId in @($runs.Keys)) {
        if ($done.ContainsKey([long]$runId)) { continue }
        try {
            $b = Invoke-AdoGet "build/builds/$($runId)?api-version=7.1"
            $hasPendingReq = @($existing.Values | Where-Object { $_.status -eq 'pending' -and [long]$_.runId -eq [long]$runId }).Count -gt 0
            if ($b.status -eq 'completed' -and -not $hasPendingReq) { $newlyDone += [long]$runId; continue }
            $scan = Find-Approvals ([long]$runId)
            $scanned[[long]$runId] = $true
            foreach ($k in $scan.ended.Keys) { $endedByKey["$runId|$k"] = $scan.ended[$k] }
            foreach ($k in $scan.pending.Keys) {
                $p = $scan.pending[$k]
                $id = Get-ShortId "$runId|$k"
                $found[$id] = [pscustomobject]@{
                    id = $id; key = "$runId|$k"; kind = $p.kind; url = $p.url; runId = [long]$runId
                    runUrl = "https://dev.azure.com/$($script:Org)/$($script:Proj)/_build/results?buildId=$runId"
                    pipelineId = [int]$b.definition.id; pipelineName = [string]$b.definition.name; runName = [string]$b.buildNumber
                    step = $runs[$runId]; stages = @($p.stages); waitingSince = $p.waitingSince; expiresAt = $p.expiresAt
                }
            }
            if ($b.status -eq 'completed') { $newlyDone += [long]$runId }
        } catch {
            Write-Audit @{ event = 'approval-watch-run-error'; runId = $runId; error = $_.Exception.Message }
        }
    }

    $events = New-Object System.Collections.Generic.List[object]
    $now = Get-UtcNow
    $updated = @{}
    # new / still pending
    foreach ($id in $found.Keys) {
        $f = $found[$id]
        $req = if ($existing.ContainsKey($id)) { $existing[$id] | ConvertTo-Json -Depth 8 | ConvertFrom-Json } else { $null }
        $ev = $null
        if (-not $req -or $req.status -ne 'pending') {
            $req = $f
            Add-Member -InputObject $req -NotePropertyName status -NotePropertyValue 'pending' -Force
            Add-Member -InputObject $req -NotePropertyName firstSeenAt -NotePropertyValue (Get-NowIso) -Force
            Add-Member -InputObject $req -NotePropertyName notifyCount -NotePropertyValue 0 -Force
            Add-Member -InputObject $req -NotePropertyName lastNotifiedAt -NotePropertyValue $null -Force
            Add-Member -InputObject $req -NotePropertyName expiryWarnedAt -NotePropertyValue $null -Force
            $ev = 'approval-needed'
            Write-Audit @{ event = 'approval-detected'; id = $id; kind = $f.kind; runId = $f.runId; url = $f.url; stages = @($f.stages) }
        } else {
            foreach ($n in 'stages', 'expiresAt', 'waitingSince', 'url') { if ($f.$n) { Add-Member -InputObject $req -NotePropertyName $n -NotePropertyValue $f.$n -Force } }
            $exp = if ($req.expiresAt) { ConvertTo-UtcDate $req.expiresAt } else { $null }
            $last = if ($req.lastNotifiedAt) { ConvertTo-UtcDate $req.lastNotifiedAt } else { $null }
            if ($exp -and -not $req.expiryWarnedAt -and ($exp - $now).TotalHours -le $ExpiryWarnHours) { $ev = 'approval-expiring' }
            elseif ($ReminderHours -gt 0 -and $last -and ($now - $last).TotalHours -ge $ReminderHours) { $ev = 'approval-reminder' }
        }
        if ($ev) {
            $req.notifyCount = [int]$req.notifyCount + 1
            $req.lastNotifiedAt = Get-NowIso
            if ($ev -eq 'approval-expiring') { $req.expiryWarnedAt = Get-NowIso }
            Add-Member -InputObject $req -NotePropertyName lastMessage -NotePropertyValue (New-Message $req $ev $release) -Force
            $events.Add([pscustomobject]@{ event = $ev; id = $id; eventKey = $req.lastMessage.eventKey })
        }
        $updated[$id] = $req
    }
    # previously pending, no longer pending (only for runs we could read this tick)
    foreach ($id in $existing.Keys) {
        if ($found.ContainsKey($id)) { continue }
        $req = $existing[$id]
        if ($req.status -ne 'pending' -or -not $scanned.ContainsKey([long]$req.runId)) { continue }
        $req = $req | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $result = if ($endedByKey.ContainsKey($req.key)) { $endedByKey[$req.key] } else { 'succeeded' }
        Add-Member -InputObject $req -NotePropertyName endedResult -NotePropertyValue $result -Force
        Add-Member -InputObject $req -NotePropertyName endedAt -NotePropertyValue (Get-NowIso) -Force
        if ($result -eq 'succeeded') {
            $req.status = 'approved'
            Write-Audit @{ event = 'approval-approved'; id = $id; runId = $req.runId; url = $req.url }
        } else {
            $req.status = 'ended'
            Add-Member -InputObject $req -NotePropertyName lastMessage -NotePropertyValue (New-Message $req 'approval-failed' $release) -Force
            $events.Add([pscustomobject]@{ event = 'approval-failed'; id = $id; eventKey = 'approval-failed' })
            Write-Audit @{ event = 'approval-ended'; id = $id; runId = $req.runId; result = $result }
        }
        $updated[$id] = $req
    }

    $sf = $StateFile
    Invoke-WithStateLock -LockFile $StateLock -Action ({
        $st = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $st.PSObject.Properties['approvalRequests'] -or $null -eq $st.approvalRequests) { Add-Member -InputObject $st -NotePropertyName approvalRequests -NotePropertyValue ([pscustomobject]@{}) -Force }
        foreach ($id in $updated.Keys) { Add-Member -InputObject $st.approvalRequests -NotePropertyName $id -NotePropertyValue $updated[$id] -Force }
        if (-not $st.PSObject.Properties['approvalWatch'] -or $null -eq $st.approvalWatch) { Add-Member -InputObject $st -NotePropertyName approvalWatch -NotePropertyValue ([pscustomobject]@{ doneRuns = @() }) -Force }
        $doneAll = @(@($st.approvalWatch.doneRuns) + $newlyDone | Where-Object { $_ } | ForEach-Object { [long]$_ } | Select-Object -Unique)
        Add-Member -InputObject $st.approvalWatch -NotePropertyName doneRuns -NotePropertyValue $doneAll -Force
        Add-Member -InputObject $st.approvalWatch -NotePropertyName lastSyncAt -NotePropertyValue (Get-NowIso) -Force
        Add-Member -InputObject $st -NotePropertyName lastUpdated -NotePropertyValue (Get-NowIso) -Force
        $st | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $sf -Encoding UTF8 -NoNewline
    })

    $out.NotifyEvents = $events.ToArray()
    $out.Pending = @($updated.Values | Where-Object { $_.status -eq 'pending' })
    $out.Success = $true
} catch {
    $out.Error = $_.Exception.Message
    try { Write-Audit @{ event = 'approval-watch-error'; error = $_.Exception.Message } } catch { }
}

return $out
