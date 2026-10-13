<#
.SYNOPSIS
    Schedule guard for canary pipelines that also deploy on their own (BCM EA-CAN runs develop
    daily). Pauses the pipeline's own deployments while the release bits must stay on its
    stamps, then restores them.

.DESCRIPTION
    Configured per canary pipeline in pipeline-catalog.json:
        canary.<key>.scheduleGuard = { variable: "enableSchedule", disabledValue: "false", enabledValue: "true" }

    Lifecycle (state.json → scheduleGuards.<key>):
      1. DISABLE — as soon as ZED's own Step 5 run of <key> (a run id in state.triggeredPipelines.5
         for that definition) completes with result 'succeeded', set the definition variable to
         <disabledValue>. Failed/cancelled runs never disable (nothing to protect; covers test mode,
         whose runs are cancelled at trigger).
      2. RESTORE — when Step 6 BVT is signed off (`approve-bvt`) set it back to <enabledValue>.
         Safety net: Sync also restores whenever Step 6 is completed or skipped by any path, and
         Step 7 / teardown call Restore before doing anything else. ZED never triggers a guarded
         pipeline while it is still disabled by ZED — its first stage is gated on the variable, so
         the run would be silently skipped.
      Only values ZED changed are restored. If the variable was already <disabledValue> before ZED
      touched it (status 'preexisting'), ZED leaves it alone; if someone changed it back before the
      sign-off, ZED records that and does not PUT.

    Statuses: disabled | restored | preexisting | armed | disable-failed | restore-failed

    Actions:
      Sync     Watcher / cold-resume side-channel (every tick) and Step 5 completion. Disables
               after a succeeded Step 5 run; restores once Step 6 is completed/skipped; retries
               failures. Never throws — errors are returned per guard.
      Disable  Explicit disable of -PipelineKey for -RunId (agent fallback).
      Restore  Restores every guard ZED disabled (or only -PipelineKey). Used by approve-bvt,
               Step 7 pre-trigger, teardown, and `rebuild` before it re-queues a guarded pipeline.
      Rearm    After `rebuild` re-queued -PipelineKey as run -RunId (before Step 6 is signed off):
               status 'armed' — Sync disables again only once THAT run succeeds (never on the
               older Step 5 run, which would skip the new run's gated stage).
      Get      Returns state.scheduleGuards.

    -Preview builds the definition PUT body and returns it without sending (for verification).

.OUTPUTS
    PSCustomObject: Success, Action, Results[] (key, status, changed, previousValue, newValue,
    revision, notifyEvent, error), NotifyEvents[], Error
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

# Sets <variable> on the definition. Returns @{ previous; new; revision; changed; body }.
function Set-DefinitionVariable([int]$DefinitionId, [string]$Variable, [string]$Value, [string]$OnlyIfCurrent) {
    $base = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/build/definitions/$DefinitionId"
    $cfj = @{ AsHashtable = $true; Depth = 100 }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $cfj.DateKind = 'String' }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
        $raw = Invoke-WebRequest -Uri "$($base)?api-version=7.1" -Headers $headers -UseBasicParsing -ErrorAction Stop
        $def = $raw.Content | ConvertFrom-Json @cfj
        if (-not $def.ContainsKey('variables') -or $null -eq $def['variables'] -or -not $def['variables'].ContainsKey($Variable)) {
            throw "Variable '$Variable' is not defined on pipeline $DefinitionId (Pipeline settings → Variables)."
        }
        $prevVal = [string]$def['variables'][$Variable]['value']
        if ($OnlyIfCurrent -and $prevVal -ne $OnlyIfCurrent) {
            return @{ previous = $prevVal; new = $prevVal; revision = $def['revision']; changed = $false; skippedBecause = 'value-changed-by-someone-else' }
        }
        if ($prevVal -eq $Value) {
            return @{ previous = $prevVal; new = $prevVal; revision = $def['revision']; changed = $false }
        }
        $def['variables'][$Variable]['value'] = $Value
        $body = $def | ConvertTo-Json -Depth 100 -Compress
        if ($script:Preview) {
            return @{ previous = $prevVal; new = $Value; revision = $def['revision']; changed = $false; preview = $true; body = $body; original = $raw.Content }
        }
        try {
            $resp = Invoke-RestMethod -Uri "$($base)?api-version=7.1" -Method PUT -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $body -ErrorAction Stop
            return @{ previous = $prevVal; new = $Value; revision = $resp.revision; changed = $true }
        } catch {
            $msg = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($attempt -lt 3 -and $msg -match '(?i)revision|conflict|409') { Start-Sleep -Seconds (2 * $attempt); continue }
            throw
        }
    }
}

function Invoke-Disable([string]$Key, $Entry, [int]$Run) {
    $sg = $Entry.scheduleGuard
    $disabledValue = if ($sg.PSObject.Properties['disabledValue'] -and $null -ne $sg.disabledValue) { [string]$sg.disabledValue } else { 'false' }
    $prior = Get-Guard (Read-State) $Key
    try {
        $r = Set-DefinitionVariable -DefinitionId ([int]$Entry.id) -Variable $sg.variable -Value $disabledValue
        if ($r.preview) {
            $results.Add([pscustomobject]@{ key = $Key; status = 'preview'; changed = $false; previousValue = $r.previous; newValue = $r.new; revision = $r.revision; body = $r.body; original = $r.original; notifyEvent = $null; error = $null })
            return
        }
        $status = if ($r.changed) { 'disabled' } else { 'preexisting' }
        $evt = if ($r.changed) { 'schedule-guard-disabled' } else { 'schedule-guard-preexisting' }
        Save-Guard $Key @{
            pipelineId = [int]$Entry.id; variable = [string]$sg.variable; status = $status
            originalValue = $r.previous; disabledAt = (Get-NowIso); disabledByRunId = $Run
            revision = $r.revision; error = $null; lastNotifiedError = $null
        }
        Write-Audit @{ event = "schedule-guard-$status"; pipelineKey = $Key; variable = $sg.variable; previousValue = $r.previous; newValue = $r.new; runId = $Run; revision = $r.revision }
        $results.Add([pscustomobject]@{ key = $Key; status = $status; changed = $r.changed; previousValue = $r.previous; newValue = $r.new; revision = $r.revision; notifyEvent = $evt; error = $null })
    } catch {
        $err = $_.Exception.Message
        $notify = if ($prior -and $prior.PSObject.Properties['lastNotifiedError'] -and $prior.lastNotifiedError -eq $err) { $null } else { 'schedule-guard-failed' }
        Save-Guard $Key @{ pipelineId = [int]$Entry.id; variable = [string]$sg.variable; status = 'disable-failed'; error = $err; disabledByRunId = $Run; lastNotifiedError = $err; failedAt = (Get-NowIso) }
        Write-Audit @{ event = 'schedule-guard-disable-failed'; pipelineKey = $Key; error = $err }
        $results.Add([pscustomobject]@{ key = $Key; status = 'disable-failed'; changed = $false; notifyEvent = $notify; error = $err })
    }
}

function Invoke-Restore([string]$Key, $Entry, [string]$Why) {
    $sg = $Entry.scheduleGuard
    $disabledValue = if ($sg.PSObject.Properties['disabledValue'] -and $null -ne $sg.disabledValue) { [string]$sg.disabledValue } else { 'false' }
    $enabledValue = if ($sg.PSObject.Properties['enabledValue'] -and $null -ne $sg.enabledValue) { [string]$sg.enabledValue } else { 'true' }
    $prior = Get-Guard (Read-State) $Key
    try {
        $r = Set-DefinitionVariable -DefinitionId ([int]$Entry.id) -Variable $sg.variable -Value $enabledValue -OnlyIfCurrent $disabledValue
        if ($r.preview) {
            $results.Add([pscustomobject]@{ key = $Key; status = 'preview'; changed = $false; previousValue = $r.previous; newValue = $r.new; revision = $r.revision; body = $r.body; original = $r.original; notifyEvent = $null; error = $null })
            return
        }
        $note = if ($r.skippedBecause) { "already '$($r.previous)' — changed outside ZED, left as is" } else { $null }
        Save-Guard $Key @{ status = 'restored'; restoredAt = (Get-NowIso); restoreReason = $Why; restoredValue = $r.new; revision = $r.revision; error = $null; note = $note; lastNotifiedError = $null }
        Write-Audit @{ event = 'schedule-guard-restored'; pipelineKey = $Key; variable = $sg.variable; previousValue = $r.previous; newValue = $r.new; reason = $Why; note = $note }
        $results.Add([pscustomobject]@{ key = $Key; status = 'restored'; changed = $r.changed; previousValue = $r.previous; newValue = $r.new; revision = $r.revision; notifyEvent = 'schedule-guard-restored'; error = $null; note = $note })
    } catch {
        $err = $_.Exception.Message
        $notify = if ($prior -and $prior.PSObject.Properties['lastNotifiedError'] -and $prior.lastNotifiedError -eq $err) { $null } else { 'schedule-guard-failed' }
        Save-Guard $Key @{ status = 'restore-failed'; error = $err; lastNotifiedError = $err; failedAt = (Get-NowIso); restoreReason = $Why }
        Write-Audit @{ event = 'schedule-guard-restore-failed'; pipelineKey = $Key; error = $err }
        $results.Add([pscustomobject]@{ key = $Key; status = 'restore-failed'; changed = $false; notifyEvent = $notify; error = $err })
    }
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
            if ($p.Value.PSObject.Properties['scheduleGuard'] -and $p.Value.scheduleGuard -and $p.Value.scheduleGuard.variable) { $guarded[$p.Name] = $p.Value }
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
                if ($testMode -or @('disabled', 'preexisting', 'restored', 'restore-failed') -contains $gs) { continue }
                if (@('in-progress', 'completed') -notcontains $step5) { continue }
                if ($gs -eq 'armed') {
                    # rebuild: only the re-queued run counts
                    $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
                    $b = Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/$Project/_apis/build/builds/$([int]$g.awaitRunId)?api-version=7.1" -Headers $headers -ErrorAction Stop
                    if ($b.status -eq 'completed' -and $b.result -eq 'succeeded') { Invoke-Disable $k $entry ([int]$g.awaitRunId) }
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
                if ($ok) { Invoke-Disable $k $entry ([int]$ok.id) }
            }
        }
    }

    $out.Results = $results.ToArray()
    $out.NotifyEvents = [string[]]@($results | Where-Object { $_.notifyEvent } | ForEach-Object { "$($_.notifyEvent):$($_.key)" })
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
