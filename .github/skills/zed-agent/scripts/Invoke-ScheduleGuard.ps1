<#
.SYNOPSIS
    Schedule guard for canary pipelines that also deploy on their own (BCM EA-CAN runs develop
    daily). Pauses the pipeline's own deployments while the release bits must stay on its
    stamps, then restores them.

.DESCRIPTION
    Configured per canary pipeline in pipeline-catalog.json (any combination):
        canary.<key>.scheduleGuard = {
            pauseScheduleTriggers: true,   # remove the pipeline's UI schedule trigger(s), re-add them verbatim
            variable: "enableSchedule", disabledValue: "false", enabledValue: "true",   # definition variable
            cancelForeignRuns: true        # cancel runs ZED did not queue while the guard is active
        }
    With pauseScheduleTriggers the variable is optional: if it is not defined on the pipeline it is
    skipped (noted), not an error. Both edits go in ONE definition PUT and need "Edit build
    pipeline"; cancelling needs only "Stop builds", so it also covers a failed disable.

    YAML pipelines: removing the UI schedule makes ADO run the YAML `schedules:` cron instead — the
    disable result carries a `warning` when the YAML on the scheduled branch still has one
    (cancelForeignRuns then cancels those runs).

    Lifecycle (state.json → scheduleGuards.<key>):
      1. DISABLE — as soon as ZED's own Step 5 run of <key> (a run id in state.triggeredPipelines.5
         for that definition) completes with result 'succeeded': remove the schedule trigger(s)
         (saved in triggersRemovedJson) and/or set the variable to <disabledValue>. Failed/cancelled
         runs never disable (nothing to protect; covers test mode, whose runs are cancelled at trigger).
      2. GUARD WINDOW — until Step 6 is signed off, Sync cancels every queued/running run of <key>
         that ZED did not queue (cancelForeignRuns): manual develop runs, cron runs. A run queued
         before ZED's Step 5 run is cancelled only once it starts. Recorded in cancelledRuns[].
      3. RESTORE — when Step 6 BVT is signed off (`approve-bvt`) re-add the saved schedule
         trigger(s) and/or set the variable back to <enabledValue>.
         Safety net: Sync also restores whenever Step 6 is completed or skipped by any path, and
         Step 7 / teardown call Restore before doing anything else. ZED never triggers a guarded
         pipeline while it is still disabled by ZED — with the variable, its first stage is gated
         on it, so the run would be silently skipped.
      Only what ZED changed is restored. If nothing needed changing (status 'preexisting'), ZED
      leaves it alone; if someone re-added a schedule / changed the variable back before the
      sign-off, ZED records that and does not touch it.

    Statuses: disabled | restored | preexisting | armed | disable-failed | restore-failed

    Actions:
      Sync     Watcher / cold-resume side-channel (every tick) and Step 5 completion. Disables
               after a succeeded Step 5 run; cancels foreign runs during the window; restores once
               Step 6 is completed/skipped; retries failures. Never throws — errors are returned per guard.
      Disable  Explicit disable of -PipelineKey for -RunId (agent fallback).
      Restore  Restores every guard ZED disabled (or only -PipelineKey). Used by approve-bvt,
               Step 7 pre-trigger, teardown, and `rebuild` before it re-queues a guarded pipeline.
      Rearm    After `rebuild` re-queued -PipelineKey as run -RunId (before Step 6 is signed off):
               status 'armed' — Sync disables again only once THAT run succeeds (never on the
               older Step 5 run, which would skip the new run's gated stage).
      Get      Returns state.scheduleGuards.

    -Preview builds the definition PUT body and returns it without sending (for verification);
    in Sync it reports runs it would cancel ('would-cancel') without cancelling them.

.OUTPUTS
    PSCustomObject: Success, Action, Results[] (key, status, changed, previousValue, newValue,
    schedules, warning, note, revision, runId/requestedFor/requestedForEmail/url for run events,
    notifyEvent, error), NotifyEvents[] ("<event>:<key>" or "<event>:<key>:<runId>"), Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Sync', 'Disable', 'Restore', 'Rearm', 'Get')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$PipelineKey,
    [int]$RunId,
    [string]$Reason,
    [string]$StateFile,
    [string]$StateLock,
    [string]$AuditFile,
    [string]$ReleaseFile,
    [string]$PipelineCatalogPath,
    [string]$ServiceConfigPath,
    [string]$Organization,
    [string]$Project,
    [string]$AccessToken,
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

$out = [pscustomobject]@{
    Success      = $false
    Action       = $Action
    Results      = @()
    NotifyEvents = @()
    Error        = $null
}
$results = New-Object System.Collections.Generic.List[object]

function Get-NowIso { (Get-Date).ToUniversalTime().ToString('o') }

function Write-Audit([hashtable]$Entry) {
    try {
        $Entry.ts = Get-NowIso
        $Entry | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $script:AuditFile -Encoding UTF8
    } catch { }
}

function Read-State { Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-StepStatus($State, [int]$N) {
    $s = $State.steps | Where-Object { $_.number -eq $N } | Select-Object -First 1
    if ($s) { [string]$s.status } else { $null }
}

function Get-Guard($State, [string]$Key) {
    if ($State.PSObject.Properties['scheduleGuards'] -and $State.scheduleGuards -and $State.scheduleGuards.PSObject.Properties[$Key]) {
        return $State.scheduleGuards.$Key
    }
    return $null
}

function Save-Guard([string]$Key, [hashtable]$Fields) {
    Invoke-WithStateLock -LockFile $script:StateLock -Action ({
        $st = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $st.PSObject.Properties['scheduleGuards'] -or $null -eq $st.scheduleGuards) {
            Add-Member -InputObject $st -MemberType NoteProperty -Name scheduleGuards -Value ([pscustomobject]@{}) -Force
        }
        if (-not $st.scheduleGuards.PSObject.Properties[$Key]) {
            Add-Member -InputObject $st.scheduleGuards -MemberType NoteProperty -Name $Key -Value ([pscustomobject]@{}) -Force
        }
        $g = $st.scheduleGuards.$Key
        foreach ($k in $Fields.Keys) {
            if ($g.PSObject.Properties[$k]) { $g.$k = $Fields[$k] }
            else { Add-Member -InputObject $g -MemberType NoteProperty -Name $k -Value $Fields[$k] -Force }
        }
        Add-Member -InputObject $st -MemberType NoteProperty -Name lastUpdated -Value (Get-NowIso) -Force
        $st | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 -NoNewline
    })
}

function Get-AdoToken {
    if ($script:AccessToken) { return $script:AccessToken }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $t = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null }
    finally { $ErrorActionPreference = $prev }
    if (-not $t) { throw "Failed to acquire ADO token. Run 'az login --tenant microsoft.com'." }
    $script:AccessToken = $t
    return $t
}

function Get-RunIds($State) {
    $ids = @()
    foreach ($src in @($State, $script:Release)) {
        if ($null -eq $src) { continue }
        $tp = $src.PSObject.Properties['triggeredPipelines']
        if ($tp -and $tp.Value -and $tp.Value.PSObject.Properties['5']) {
            foreach ($v in @($tp.Value.'5')) {
                $id = if ($v -is [psobject] -and $v.PSObject.Properties['runId']) { $v.runId } elseif ($v -is [psobject] -and $v.PSObject.Properties['id']) { $v.id } else { $v }
                if ("$id" -match '^\d+$') { $ids += [int]$id }
            }
        }
    }
    return @($ids | Select-Object -Unique)
}

function ConvertTo-UtcDate($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }
        return $v.ToUniversalTime()
    }
    return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

# Every run id ZED queued in this release (any step) — never cancelled as a "foreign" run.
function Get-ZedRunIds($State) {
    $ids = New-Object System.Collections.Generic.HashSet[long]
    foreach ($src in @($State, $script:Release)) {
        if ($null -eq $src) { continue }
        $tp = $src.PSObject.Properties['triggeredPipelines']
        if (-not $tp -or -not $tp.Value) { continue }
        foreach ($p in $tp.Value.PSObject.Properties) {
            foreach ($v in @($p.Value)) {
                $id = if ($v -is [psobject] -and $v.PSObject.Properties['runId']) { $v.runId } elseif ($v -is [psobject] -and $v.PSObject.Properties['id']) { $v.id } elseif ($v -is [psobject] -and $v.PSObject.Properties['buildId']) { $v.buildId } else { $v }
                if ("$id" -match '^\d+$') { [void]$ids.Add([long]$id) }
            }
        }
    }
    return , $ids
}

function Get-GuardFlag($Sg, [string]$Name) { [bool]($Sg.PSObject.Properties[$Name] -and $Sg.$Name) }

# Human summary of schedule triggers, e.g. "develop Sun,Mon,Tue,Wed,Thu 23:00 India Standard Time".
function Format-Schedules($Triggers) {
    $names = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
    $parts = foreach ($t in @($Triggers)) {
        foreach ($s in @($t['schedules'])) {
            if ($null -eq $s) { continue }
            $days = [int]$s['daysToBuild']
            $dl = @(for ($i = 0; $i -lt 7; $i++) { if ($days -band (1 -shl $i)) { $names[$i] } }) -join ','
            $br = @($s['branchFilters'] | ForEach-Object { ([string]$_) -replace '^\+?refs/heads/', '' }) -join '+'
            '{0} {1} {2:00}:{3:00} {4}' -f $br, $dl, [int]$s['startHours'], [int]$s['startMinutes'], $s['timeZoneId']
        }
    }
    return (@($parts) -join '; ')
}

# YAML pipelines: once the UI schedule triggers are gone, ADO runs the YAML `schedules:` cron
# instead. Returns a warning when the YAML on the scheduled branch still has one (best effort).
function Get-YamlCronWarning($Def, $Removed) {
    try {
        if (-not $Def.ContainsKey('process') -or [int]$Def['process']['type'] -ne 2) { return $null }
        $path = [string]$Def['process']['yamlFilename']; $repo = [string]$Def['repository']['id']
        $branch = @(@($Removed) | ForEach-Object { @($_['schedules']) } | ForEach-Object { @($_['branchFilters']) } |
            Where-Object { "$_" -match '^\+?refs/heads/' } | ForEach-Object { ([string]$_) -replace '^\+?refs/heads/', '' }) | Select-Object -First 1
        if (-not $path -or -not $repo -or -not $branch) { return $null }
        $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
        $u = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/git/repositories/$repo/items?path=$([uri]::EscapeDataString($path))&versionDescriptor.version=$([uri]::EscapeDataString($branch))&versionDescriptor.versionType=branch&includeContent=true&api-version=7.1"
        $item = Invoke-RestMethod -Uri $u -Headers $headers -ErrorAction Stop
        # a single file comes back as raw text unless JSON is negotiated
        $content = if ($item -is [string]) { $item } else { [string]$item.content }
        if ($content -match '(?m)^\s*schedules\s*:' -and $content -match '(?m)^\s*-\s*cron\s*:') {
            return "The YAML on '$branch' ($path) still has a 'schedules:' cron. With the UI schedule trigger removed, ADO runs that cron instead — ZED cancels those runs while the guard is active, but remove the cron from the YAML to stop them at the source."
        }
    } catch { }
    return $null
}

# Applies the guard to the definition in ONE read-modify-PUT (revision retry):
#   variable mode        — <variable> := disabledValue / enabledValue
#   pauseScheduleTriggers — remove every 'schedule' trigger (saved verbatim in state) / re-add them
# $Mode 'disable' | 'restore'; $Guard = current state.scheduleGuards.<key> (restore needs it).
function Update-GuardedDefinition([int]$DefinitionId, $Sg, [string]$Mode, $Guard) {
    $base = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/build/definitions/$DefinitionId"
    $useVar = Get-GuardFlag $Sg 'variable'
    $useTrig = Get-GuardFlag $Sg 'pauseScheduleTriggers'
    $disabledValue = if ($Sg.PSObject.Properties['disabledValue'] -and $null -ne $Sg.disabledValue) { [string]$Sg.disabledValue } else { 'false' }
    $enabledValue = if ($Sg.PSObject.Properties['enabledValue'] -and $null -ne $Sg.enabledValue) { [string]$Sg.enabledValue } else { 'true' }
    $cfj = @{ AsHashtable = $true; Depth = 100 }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $cfj.DateKind = 'String' }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
        $raw = Invoke-WebRequest -Uri "$($base)?api-version=7.1" -Headers $headers -UseBasicParsing -ErrorAction Stop
        $def = $raw.Content | ConvertFrom-Json @cfj
        $info = @{ changed = $false; revision = $def['revision']; previous = $null; new = $null; variableChanged = $false; notes = @() }
        $dirty = $false

        if ($useVar) {
            $var = [string]$Sg.variable
            $hasVar = $def.ContainsKey('variables') -and $null -ne $def['variables'] -and $def['variables'].ContainsKey($var)
            if (-not $hasVar) {
                if (-not $useTrig) { throw "Variable '$var' is not defined on pipeline $DefinitionId (Pipeline settings → Variables)." }
                $info.variableMissing = $true
            } else {
                $prev = [string]$def['variables'][$var]['value']
                $info.previous = $prev; $info.new = $prev
                if ($Mode -eq 'disable') {
                    if ($prev -ne $disabledValue) { $def['variables'][$var]['value'] = $disabledValue; $info.new = $disabledValue; $info.variableChanged = $true; $dirty = $true }
                } else {
                    # Older guards (variable-only) have no variableChanged field: status 'disabled' meant ZED changed it.
                    $zedChanged = if ($Guard -and $Guard.PSObject.Properties['variableChanged']) { [bool]$Guard.variableChanged } else { -not $useTrig }
                    if ($zedChanged) {
                        if ($prev -eq $disabledValue) { $def['variables'][$var]['value'] = $enabledValue; $info.new = $enabledValue; $info.variableChanged = $true; $dirty = $true }
                        else { $info.notes += "$var already '$prev' — changed outside ZED, left as is"; $info.skippedBecause = 'value-changed-by-someone-else' }
                    }
                }
            }
        }

        if ($useTrig) {
            $trigs = @(if ($def.ContainsKey('triggers') -and $null -ne $def['triggers']) { $def['triggers'] })
            $sched = @($trigs | Where-Object { $_ -and $_['triggerType'] -eq 'schedule' })
            if ($Mode -eq 'disable') {
                if ($sched.Count -gt 0) {
                    $info.triggersRemovedJson = ConvertTo-Json -InputObject $sched -Depth 50 -Compress
                    $info.schedules = Format-Schedules $sched
                    $info.removedTriggers = $sched
                    $def['triggers'] = @($trigs | Where-Object { -not ($_ -and $_['triggerType'] -eq 'schedule') })
                    $dirty = $true
                } else { $info.noScheduleTrigger = $true }
            } else {
                $saved = if ($Guard -and $Guard.PSObject.Properties['triggersRemovedJson']) { [string]$Guard.triggersRemovedJson } else { $null }
                if ($saved) {
                    if ($sched.Count -gt 0) {
                        $info.notes += "a schedule trigger is already present ($(Format-Schedules $sched)) — changed outside ZED, left as is"
                    } else {
                        $re = @($saved | ConvertFrom-Json @cfj -NoEnumerate)
                        if ($re.Count -eq 1 -and $re[0] -is [System.Collections.IList]) { $re = @($re[0]) }
                        $def['triggers'] = @($trigs) + $re
                        $info.schedules = Format-Schedules $re
                        $info.triggersRestored = $true
                        $dirty = $true
                    }
                }
            }
        }

        if (-not $dirty) { return $info }
        $body = $def | ConvertTo-Json -Depth 100 -Compress
        if ($script:Preview) { $info.preview = $true; $info.body = $body; $info.original = $raw.Content; return $info }
        try {
            $resp = Invoke-RestMethod -Uri "$($base)?api-version=7.1" -Method PUT -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $body -ErrorAction Stop
            $info.changed = $true; $info.revision = $resp.revision
            if ($Mode -eq 'disable' -and $info.removedTriggers) { $info.warning = Get-YamlCronWarning $def $info.removedTriggers }
            return $info
        } catch {
            $msg = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($attempt -lt 3 -and $msg -match '(?i)revision|conflict|409') { Start-Sleep -Seconds (2 * $attempt); continue }
            throw
        }
    }
}

function Get-GuardLabel($Sg) {
    $p = @()
    if (Get-GuardFlag $Sg 'pauseScheduleTriggers') { $p += 'schedule trigger' }
    if (Get-GuardFlag $Sg 'variable') { $p += [string]$Sg.variable }
    return ($p -join ' + ')
}

function Invoke-Disable([string]$Key, $Entry, [int]$Run, $WindowStart) {
    $sg = $Entry.scheduleGuard
    $prior = Get-Guard (Read-State) $Key
    $ws = if ($WindowStart) { (ConvertTo-UtcDate $WindowStart).ToString('o') } elseif ($prior -and $prior.PSObject.Properties['windowStart'] -and $prior.windowStart) { [string]$prior.windowStart } else { Get-NowIso }
    try {
        $r = Update-GuardedDefinition -DefinitionId ([int]$Entry.id) -Sg $sg -Mode 'disable' -Guard $prior
        if ($r.preview -or $script:Preview) {
            $results.Add([pscustomobject]@{ key = $Key; status = 'preview'; changed = $false; previousValue = $r.previous; newValue = $r.new; schedules = $r.schedules; revision = $r.revision; body = $r.body; original = $r.original; notifyEvent = $null; error = $null })
            return
        }
        $status = if ($r.changed) { 'disabled' } else { 'preexisting' }
        $evt = if ($r.changed) { 'schedule-guard-disabled' } else { 'schedule-guard-preexisting' }
        $note = @($r.notes) + @($(if ($r.variableMissing) { "variable '$($sg.variable)' is not defined on the pipeline — skipped" })) + @($(if ($r.noScheduleTrigger) { 'no schedule trigger on the pipeline' })) | Where-Object { $_ }
        $note = if (@($note).Count) { @($note) -join '; ' } else { $null }
        Save-Guard $Key @{
            pipelineId = [int]$Entry.id; variable = [string]$sg.variable; guards = (Get-GuardLabel $sg); status = $status
            originalValue = $r.previous; variableChanged = [bool]$r.variableChanged
            triggersRemovedJson = $r.triggersRemovedJson; schedules = $r.schedules; warning = $r.warning; note = $note
            disabledAt = (Get-NowIso); disabledByRunId = $Run; windowStart = $ws
            revision = $r.revision; error = $null; lastNotifiedError = $null
        }
        Write-Audit @{ event = "schedule-guard-$status"; pipelineKey = $Key; variable = $sg.variable; previousValue = $r.previous; newValue = $r.new; schedulesRemoved = $r.schedules; runId = $Run; revision = $r.revision; warning = $r.warning; note = $note }
        $results.Add([pscustomobject]@{ key = $Key; status = $status; changed = $r.changed; previousValue = $r.previous; newValue = $r.new; schedules = $r.schedules; warning = $r.warning; note = $note; revision = $r.revision; notifyEvent = $evt; error = $null })
    } catch {
        $err = $_.Exception.Message
        $notify = if ($prior -and $prior.PSObject.Properties['lastNotifiedError'] -and $prior.lastNotifiedError -eq $err) { $null } else { 'schedule-guard-failed' }
        Save-Guard $Key @{ pipelineId = [int]$Entry.id; variable = [string]$sg.variable; guards = (Get-GuardLabel $sg); status = 'disable-failed'; error = $err; disabledByRunId = $Run; windowStart = $ws; lastNotifiedError = $err; failedAt = (Get-NowIso) }
        Write-Audit @{ event = 'schedule-guard-disable-failed'; pipelineKey = $Key; error = $err }
        $results.Add([pscustomobject]@{ key = $Key; status = 'disable-failed'; changed = $false; notifyEvent = $notify; error = $err })
    }
}

function Invoke-Restore([string]$Key, $Entry, [string]$Why) {
    $sg = $Entry.scheduleGuard
    $prior = Get-Guard (Read-State) $Key
    try {
        $r = Update-GuardedDefinition -DefinitionId ([int]$Entry.id) -Sg $sg -Mode 'restore' -Guard $prior
        if ($r.preview -or $script:Preview) {
            $results.Add([pscustomobject]@{ key = $Key; status = 'preview'; changed = $false; previousValue = $r.previous; newValue = $r.new; schedules = $r.schedules; revision = $r.revision; body = $r.body; original = $r.original; note = $(if (@($r.notes).Count) { @($r.notes) -join '; ' } else { $null }); notifyEvent = $null; error = $null })
            return
        }
        $note = if (@($r.notes).Count) { @($r.notes) -join '; ' } else { $null }
        Save-Guard $Key @{ status = 'restored'; restoredAt = (Get-NowIso); restoreReason = $Why; restoredValue = $r.new; schedulesRestored = $(if ($r.triggersRestored) { $r.schedules } else { $null }); revision = $r.revision; error = $null; note = $note; lastNotifiedError = $null }
        Write-Audit @{ event = 'schedule-guard-restored'; pipelineKey = $Key; variable = $sg.variable; previousValue = $r.previous; newValue = $r.new; schedulesRestored = $(if ($r.triggersRestored) { $r.schedules } else { $null }); reason = $Why; note = $note }
        $results.Add([pscustomobject]@{ key = $Key; status = 'restored'; changed = $r.changed; previousValue = $r.previous; newValue = $r.new; schedules = $(if ($r.triggersRestored) { $r.schedules } else { $null }); revision = $r.revision; notifyEvent = 'schedule-guard-restored'; error = $null; note = $note })
    } catch {
        $err = $_.Exception.Message
        $notify = if ($prior -and $prior.PSObject.Properties['lastNotifiedError'] -and $prior.lastNotifiedError -eq $err) { $null } else { 'schedule-guard-failed' }
        Save-Guard $Key @{ status = 'restore-failed'; error = $err; lastNotifiedError = $err; failedAt = (Get-NowIso); restoreReason = $Why }
        Write-Audit @{ event = 'schedule-guard-restore-failed'; pipelineKey = $Key; error = $err }
        $results.Add([pscustomobject]@{ key = $Key; status = 'restore-failed'; changed = $false; notifyEvent = $notify; error = $err })
    }
}

# While the guard window is open (ZED's Step 5 run succeeded → Step 6 signed off), cancel every
# run of the guarded pipeline that ZED did not queue: manual develop runs, or a YAML cron that
# took over from the removed UI schedule. A run already queued before the window is cancelled
# only once it actually starts. Needs only "Stop builds" — so it also covers a failed disable.
function Invoke-CancelForeign([string]$Key, $Entry, $State) {
    $g = Get-Guard $State $Key
    $zed = Get-ZedRunIds $State
    foreach ($n in @('disabledByRunId', 'awaitRunId')) { if ($g -and $g.PSObject.Properties[$n] -and "$($g.$n)" -match '^\d+$') { [void]$zed.Add([long]$g.$n) } }
    $done = @{}
    if ($g -and $g.PSObject.Properties['cancelledRuns']) { foreach ($c in @($g.cancelledRuns)) { if ($c) { $done["$($c.runId)"] = $c } } }
    $since = if ($g -and $g.PSObject.Properties['windowStart'] -and $g.windowStart) { ConvertTo-UtcDate $g.windowStart } else { $null }
    $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
    $resp = Invoke-RestMethod -Uri "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/build/builds?definitions=$([int]$Entry.id)&statusFilter=inProgress,notStarted&api-version=7.1" -Headers $headers -ErrorAction Stop
    $list = @($done.Values)
    $changed = $false
    foreach ($b in @($resp.value)) {
        if (-not $b -or $zed.Contains([long]$b.id)) { continue }
        $prev = $done["$($b.id)"]
        if ($prev -and $prev.status -eq 'cancelled') { continue }
        $queued = ConvertTo-UtcDate $b.queueTime
        if ($b.status -ne 'inProgress' -and -not ($since -and $queued -and $queued -ge $since)) { continue }
        $who = if ($b.requestedFor) { $b.requestedFor } else { $b.requestedBy }
        # scheduled runs are "requested for" a service identity (uniqueName <guid>@<guid>) — not a mailbox
        $mail = [string]$who.uniqueName
        if ($mail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $mail = $null }
        $rec = [pscustomobject]@{
            runId = [long]$b.id; buildNumber = [string]$b.buildNumber; sourceBranch = [string]$b.sourceBranch; reason = [string]$b.reason
            requestedFor = [string]$who.displayName; requestedForEmail = $mail
            queueTime = $(if ($queued) { $queued.ToString('o') } else { $null })
            url = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_build/results?buildId=$($b.id)"
            status = 'cancelled'; at = (Get-NowIso); error = $null
        }
        if ($script:Preview) {
            $results.Add([pscustomobject]@{ key = $Key; status = 'would-cancel'; runId = $rec.runId; requestedFor = $rec.requestedFor; requestedForEmail = $rec.requestedForEmail; sourceBranch = $rec.sourceBranch; reason = $rec.reason; url = $rec.url; notifyEvent = $null; error = $null })
            continue
        }
        $evt = 'schedule-guard-run-cancelled'
        try {
            Invoke-RestMethod -Uri "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/build/builds/$($b.id)?api-version=7.1" -Method PATCH -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body '{"status":"cancelling"}' -ErrorAction Stop | Out-Null
            Write-Audit @{ event = 'schedule-guard-run-cancelled'; pipelineKey = $Key; runId = $rec.runId; sourceBranch = $rec.sourceBranch; reason = $rec.reason; requestedFor = $rec.requestedForEmail }
        } catch {
            $rec.status = 'cancel-failed'; $rec.error = $_.Exception.Message
            # report a cancel failure once per run
            $evt = if ($prev -and $prev.status -eq 'cancel-failed') { $null } else { 'schedule-guard-cancel-failed' }
            Write-Audit @{ event = 'schedule-guard-cancel-failed'; pipelineKey = $Key; runId = $rec.runId; error = $rec.error }
        }
        $list = @($list | Where-Object { "$($_.runId)" -ne "$($rec.runId)" }) + $rec
        $changed = $true
        $results.Add([pscustomobject]@{ key = $Key; status = $rec.status; runId = $rec.runId; requestedFor = $rec.requestedFor; requestedForEmail = $rec.requestedForEmail; sourceBranch = $rec.sourceBranch; reason = $rec.reason; url = $rec.url; notifyEvent = $evt; error = $rec.error })
    }
    if ($changed) { Save-Guard $Key @{ cancelledRuns = @($list) } }
}

try {
    if (-not $StateFile -or -not $StateLock -or -not $AuditFile -or -not $ReleaseFile) {
        $paths = & (Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1') -ReleaseId $ReleaseId
        if (-not $StateFile)   { $StateFile = $paths.StateFile }
        if (-not $StateLock)   { $StateLock = $paths.LockFile }
        if (-not $AuditFile)   { $AuditFile = $paths.AuditFile }
        if (-not $ReleaseFile) { $ReleaseFile = $paths.ReleaseFile }
    }
    $script:StateFile = $StateFile; $script:StateLock = $StateLock; $script:AuditFile = $AuditFile
    $script:AccessToken = $AccessToken; $script:Preview = [bool]$Preview
    if (-not (Test-Path -LiteralPath $StateFile)) { throw "State file not found: $StateFile" }
    $script:Release = if (Test-Path -LiteralPath $ReleaseFile) { Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

    if (-not $PipelineCatalogPath) { $PipelineCatalogPath = Join-Path $PSScriptRoot '..\pipeline-catalog.json' }
    $catalog = Get-Content -LiteralPath $PipelineCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $guarded = [ordered]@{}
    if ($catalog.PSObject.Properties['canary'] -and $catalog.canary) {
        foreach ($p in $catalog.canary.PSObject.Properties) {
            $sgc = if ($p.Value.PSObject.Properties['scheduleGuard']) { $p.Value.scheduleGuard } else { $null }
            if ($sgc -and ((Get-GuardFlag $sgc 'variable') -or (Get-GuardFlag $sgc 'pauseScheduleTriggers'))) { $guarded[$p.Name] = $p.Value }
        }
    }
    if ($PipelineKey -and -not $guarded.Contains($PipelineKey)) { throw "canary.$PipelineKey has no scheduleGuard in pipeline-catalog.json." }

    if ($guarded.Count -gt 0 -and $Action -ne 'Get' -and (-not $Organization -or -not $Project)) {
        if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
        $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Organization) { $Organization = $svc.ado.organization }
        if (-not $Project) { $Project = $svc.ado.project }
    }
    $script:Organization = $Organization; $script:Project = $Project

    switch ($Action) {
        'Get' { }
        'Disable' {
            if (-not $PipelineKey -or -not $RunId) { throw "-Action Disable requires -PipelineKey and -RunId." }
            Invoke-Disable $PipelineKey $guarded[$PipelineKey] $RunId
        }
        'Restore' {
            $st = Read-State
            foreach ($k in @($guarded.Keys)) {
                if ($PipelineKey -and $k -ne $PipelineKey) { continue }
                $g = Get-Guard $st $k
                if ($Preview -or ($g -and @('disabled', 'restore-failed') -contains [string]$g.status)) {
                    Invoke-Restore $k $guarded[$k] $(if ($Reason) { $Reason } else { 'restore' })
                }
            }
        }
        'Rearm' {
            if (-not $PipelineKey -or -not $RunId) { throw "-Action Rearm requires -PipelineKey and -RunId (the newly queued run)." }
            $st = Read-State
            $g = Get-Guard $st $PipelineKey
            if ($g -and @('disabled', 'restore-failed') -contains [string]$g.status) {
                throw "canary.$PipelineKey is still disabled by ZED — run -Action Restore before re-queueing it."
            }
            if (@('completed', 'skipped') -notcontains (Get-StepStatus $st 6) -and -not ($script:Release -and $script:Release.testMode)) {
                Save-Guard $PipelineKey @{ pipelineId = [int]$guarded[$PipelineKey].id; variable = [string]$guarded[$PipelineKey].scheduleGuard.variable; status = 'armed'; awaitRunId = $RunId; armedAt = (Get-NowIso); error = $null }
                Write-Audit @{ event = 'schedule-guard-armed'; pipelineKey = $PipelineKey; runId = $RunId }
                $results.Add([pscustomobject]@{ key = $PipelineKey; status = 'armed'; changed = $false; notifyEvent = $null; error = $null })
            }
        }
        'Sync' {
            $st = Read-State
            $step5 = Get-StepStatus $st 5
            $step6 = Get-StepStatus $st 6
            $testMode = [bool]($script:Release -and $script:Release.testMode)
            $builds = $null
            foreach ($k in @($guarded.Keys)) {
                $entry = $guarded[$k]
                $g = Get-Guard $st $k
                $gs = if ($g) { [string]$g.status } else { '' }
                if (@('completed', 'skipped') -contains $step6) {
                    if (@('disabled', 'restore-failed') -contains $gs) { Invoke-Restore $k $entry "step-6-$step6" }
                    continue
                }
                if ($testMode) { continue }
                if ((Get-GuardFlag $entry.scheduleGuard 'cancelForeignRuns') -and @('disabled', 'preexisting', 'disable-failed', 'restore-failed') -contains $gs) {
                    try { Invoke-CancelForeign $k $entry $st }
                    catch {
                        Write-Audit @{ event = 'schedule-guard-cancel-check-failed'; pipelineKey = $k; error = $_.Exception.Message }
                        $results.Add([pscustomobject]@{ key = $k; status = 'cancel-check-failed'; changed = $false; notifyEvent = $null; error = $_.Exception.Message })
                    }
                }
                if (@('disabled', 'preexisting', 'restored', 'restore-failed') -contains $gs) { continue }
                if (@('in-progress', 'completed') -notcontains $step5) { continue }
                if ($gs -eq 'armed') {
                    # rebuild: only the re-queued run counts
                    $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
                    $b = Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/$Project/_apis/build/builds/$([int]$g.awaitRunId)?api-version=7.1" -Headers $headers -ErrorAction Stop
                    if ($b.status -eq 'completed' -and $b.result -eq 'succeeded') { Invoke-Disable $k $entry ([int]$g.awaitRunId) $b.queueTime }
                    continue
                }
                $ids = Get-RunIds $st
                if ($ids.Count -eq 0) { continue }
                if ($null -eq $builds) {
                    $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
                    $resp = Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/$Project/_apis/build/builds?buildIds=$($ids -join ',')&api-version=7.1" -Headers $headers -ErrorAction Stop
                    $builds = @($resp.value)
                }
                $ok = $builds | Where-Object { [int]$_.definition.id -eq [int]$entry.id -and $_.status -eq 'completed' -and $_.result -eq 'succeeded' } | Select-Object -First 1
                if ($ok) { Invoke-Disable $k $entry ([int]$ok.id) $ok.queueTime }
            }
        }
    }

    $out.Results = $results.ToArray()
    # "<event>:<key>" — run events (cancelled / cancel-failed) add ":<runId>"
    $out.NotifyEvents = [string[]]@($results | Where-Object { $_.notifyEvent } | ForEach-Object { if ($_.PSObject.Properties['runId'] -and $_.runId) { "$($_.notifyEvent):$($_.key):$($_.runId)" } else { "$($_.notifyEvent):$($_.key)" } })
    $out.Success = -not ($results | Where-Object { $_.error })
    if ($Action -eq 'Get') {
        $st = Read-State
        $out.Results = if ($st.PSObject.Properties['scheduleGuards']) { @($st.scheduleGuards) } else { @() }
        $out.Success = $true
    }
} catch {
    $out.Error = $_.Exception.Message
    $out.Results = $results.ToArray()
    if ($Action -ne 'Sync') { throw }
    Write-Audit @{ event = 'schedule-guard-sync-error'; error = $_.Exception.Message }
}

return $out
