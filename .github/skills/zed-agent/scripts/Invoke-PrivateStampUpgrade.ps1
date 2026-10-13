<#
.SYNOPSIS
    Private stamp upgrade test — side track that runs in parallel with the canary steps
    (kicked off at Step 5, joined at Step 13). Enabled by
    pipeline-catalog.json → privateStampUpgrade.enabled.

.DESCRIPTION
    Deploys two builds side by side to one private stamp instance using the private stamp
    pipeline (CONFIG[pipelines.privateStampUpgrade.id]):

        leg "last"    : ArtifactBranch = <owner-supplied last build branch>, port = LastPort
        leg "current" : ArtifactBranch = release.currentBranch (this release's build), port = CurrentPort

    Legs run sequentially: "current" is queued only after "last" succeeds. Both legs get the
    same ServiceOverrideSettings, built from privateStampUpgrade.serviceOverrideSettingsTemplate
    with {queueName} = the owner-supplied TeeWorkflowQueueName. When "current" succeeds, the
    track waits for the owner's BVT sign-off (`approve-private-stamp`). Step 13 does not start
    until the track is signed-off or skipped.

    State lives in state.json → privateStampUpgrade:
        status : awaiting-input | inputs-ready | triggering-last | deploying-last |
                 triggering-current | deploying-current | awaiting-bvt | signed-off |
                 skipped | failed
        inputs : { instance, lastPort, currentPort, lastArtifactBranch, currentArtifactBranch,
                   queueName, serviceOverrideSettings, providedAt, providedBy }
        runs   : { last: {...}, current: {...} }   (runId, url, status, result, queuedAt, finishedAt, port, artifactBranch)
        failedLeg, error, requestedAt, signedOffAt, signedOffBy, skippedAt, skippedBy, skipReason

    Actions:
        Init      Step 5 kick-off. Creates the track (awaiting-input) and returns
                  NotifyEvent 'private-stamp-input-needed'. No-op if it already exists.
                  In test mode the track is created as 'skipped' (no human input, no wait).
        SetInputs Owner's `private-stamp` command. Validates + stores the inputs, then behaves
                  like Poll (queues leg "last" once Step 3 has completed).
        Poll      Watcher / cold-resume side-channel, every tick. Starts leg "last" when inputs
                  are ready and the build exists; advances "last" → "current" → awaiting-bvt;
                  marks failures. Never throws — errors are returned in .Error.
        Retry     Re-queues the failed leg.
        SignOff   Owner's BVT sign-off (awaiting-bvt → signed-off).
        Skip      Owner skips the track (Step 13 join is released).
        Get       Returns the current track state.

    A trigger is "claimed" under the state lock (status triggering-<leg>) before the POST, so
    the watcher and an owner command can never double-queue the same leg.

.OUTPUTS
    PSCustomObject: Success, Action, Status, Transition, NotifyEvent, Run, Error, Track
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Init', 'SetInputs', 'Poll', 'Retry', 'SignOff', 'Skip', 'Get')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$Instance,
    [int]$LastPort,
    [int]$CurrentPort,
    [string]$LastArtifactBranch,
    [string]$QueueName,
    [string]$By,
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
    [int]$StaleClaimMinutes = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

$result = [pscustomobject]@{
    Success     = $false
    Action      = $Action
    Status      = $null
    Transition  = $null
    NotifyEvent = $null
    Run         = $null
    Error       = $null
    Track       = $null
}

function Write-Audit([hashtable]$Entry) {
    try {
        $Entry.ts = (Get-NowIso)
        $Entry | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $script:AuditFile -Encoding UTF8
    } catch { <# audit is best-effort #> }
}

function Get-NowIso { (Get-Date).ToUniversalTime().ToString('o') }

function Read-State { Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-Track($State) {
    if ($State.PSObject.Properties['privateStampUpgrade']) { return $State.privateStampUpgrade }
    return $null
}

# Read-modify-write of state.privateStampUpgrade under the state lock.
# $Mutator receives the current track (or $null) + full state and returns the new track,
# or $null to leave state untouched. Returns the track that is persisted (or the current one).
function Update-Track([scriptblock]$Mutator) {
    $sf = $script:StateFile
    Invoke-WithStateLock -LockFile $script:StateLock -Action ({
        $st = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
        $cur = if ($st.PSObject.Properties['privateStampUpgrade']) { $st.privateStampUpgrade } else { $null }
        $new = & $Mutator $cur $st
        if ($null -eq $new) { return $cur }
        if ($st.PSObject.Properties['privateStampUpgrade']) { $st.privateStampUpgrade = $new }
        else { Add-Member -InputObject $st -MemberType NoteProperty -Name privateStampUpgrade -Value $new -Force }
        Add-Member -InputObject $st -MemberType NoteProperty -Name lastUpdated -Value (Get-NowIso) -Force
        $st | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sf -Encoding UTF8 -NoNewline
        return $new
    })
}

function Copy-Track($Track) {
    if ($null -eq $Track) { return $null }
    return ($Track | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}

function Set-Prop($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { Add-Member -InputObject $Obj -MemberType NoteProperty -Name $Name -Value $Value -Force }
}

function Get-StepStatus($State, [int]$N) {
    $s = $State.steps | Where-Object { $_.number -eq $N } | Select-Object -First 1
    if ($s) { return [string]$s.status } else { return $null }
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

function Get-Release {
    if (-not (Test-Path -LiteralPath $script:ReleaseFile)) { throw "release.json not found: $($script:ReleaseFile)" }
    return (Get-Content -LiteralPath $script:ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-PortSpan {
    $span = 1
    if ($script:Psu.PSObject.Properties['portSpan'] -and [int]$script:Psu.portSpan -ge 1) { $span = [int]$script:Psu.portSpan }
    return $span
}

function Get-ParamName([string]$Key, [string]$Default) {
    $pn = $script:Psu.PSObject.Properties['parameterNames']
    if ($pn -and $pn.Value -and $pn.Value.PSObject.Properties[$Key] -and $pn.Value.$Key) { return [string]$pn.Value.$Key }
    return $Default
}

function New-TemplateParameters($Track, [string]$Leg) {
    $tp = [ordered]@{}
    if ($script:Psu.PSObject.Properties['templateParameters'] -and $script:Psu.templateParameters) {
        foreach ($p in $script:Psu.templateParameters.PSObject.Properties) { $tp[$p.Name] = [string]$p.Value }
    }
    $port = if ($Leg -eq 'last') { $Track.inputs.lastPort } else { $Track.inputs.currentPort }
    $artifact = if ($Leg -eq 'last') { $Track.inputs.lastArtifactBranch } else { $Track.inputs.currentArtifactBranch }
    $tp[(Get-ParamName 'instance' 'PrivateInstance')] = [string]$Track.inputs.instance
    $tp[(Get-ParamName 'port' 'WebRolePort')] = [string]$port
    $tp[(Get-ParamName 'artifactBranch' 'ArtifactBranch')] = [string]$artifact
    $tp[(Get-ParamName 'serviceOverrides' 'ServiceOverrideSettings')] = [string]$Track.inputs.serviceOverrideSettings
    return $tp
}

function Get-SourceRef($Track) {
    $tmpl = if ($script:Psu.PSObject.Properties['sourceBranch'] -and $script:Psu.sourceBranch) { [string]$script:Psu.sourceBranch } else { '{currentBranch}' }
    $b = $tmpl.Replace('{currentBranch}', [string]$Track.inputs.currentArtifactBranch)
    if ($b -notlike 'refs/*') { $b = "refs/heads/$b" }
    return $b
}

# Claims the leg under lock, POSTs the run, records the outcome. Returns the run record.
function Start-Leg([string]$Leg, [string]$FromStatus) {
    $claimed = Update-Track {
        param($cur, $st)
        if ($null -eq $cur -or $cur.status -ne $FromStatus) { return $null }
        $t = Copy-Track $cur
        Set-Prop $t 'status' "triggering-$Leg"
        Set-Prop $t 'claimedAt' (Get-NowIso)
        Set-Prop $t 'error' $null
        return $t
    }
    if ($null -eq $claimed -or $claimed.status -ne "triggering-$Leg") { return $null }

    $tp = New-TemplateParameters $claimed $Leg
    $ref = Get-SourceRef $claimed
    $orgBase = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis"
    $tpObj = New-Object PSObject
    foreach ($k in $tp.Keys) { $tpObj | Add-Member -MemberType NoteProperty -Name $k -Value $tp[$k] }
    $body = [pscustomobject]@{
        resources          = [pscustomobject]@{ repositories = [pscustomobject]@{ self = [pscustomobject]@{ refName = $ref } } }
        templateParameters = $tpObj
    } | ConvertTo-Json -Depth 8

    $run = [ordered]@{
        leg            = $Leg
        pipelineId     = [int]$script:Psu.id
        sourceBranch   = $ref
        artifactBranch = $tp[(Get-ParamName 'artifactBranch' 'ArtifactBranch')]
        port           = [int]$tp[(Get-ParamName 'port' 'WebRolePort')]
        templateParameters = [pscustomobject]$tp
        runId          = $null
        url            = $null
        status         = $null
        result         = $null
        queuedAt       = (Get-NowIso)
        finishedAt     = $null
    }
    $err = $null
    try {
        $headers = @{ Authorization = "Bearer $(Get-AdoToken)"; 'Content-Type' = 'application/json' }
        $resp = Invoke-RestMethod -Uri "$orgBase/pipelines/$($script:Psu.id)/runs?api-version=7.1" -Method POST -Headers $headers -Body $body -ErrorAction Stop
        $run.runId = $resp.id
        $run.url = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_build/results?buildId=$($resp.id)"
        $run.status = 'inProgress'
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { '' }
        $err = "Failed to queue private stamp '$Leg' run: $($_.Exception.Message)$detail"
    }

    $runObj = [pscustomobject]$run
    $final = Update-Track {
        param($cur, $st)
        $t = Copy-Track $cur
        if (-not $t.PSObject.Properties['runs'] -or $null -eq $t.runs) { Set-Prop $t 'runs' ([pscustomobject]@{}) }
        Set-Prop $t.runs $Leg $runObj
        if ($err) {
            Set-Prop $t 'status' 'failed'
            Set-Prop $t 'failedLeg' $Leg
            Set-Prop $t 'error' $err
        } else {
            Set-Prop $t 'status' "deploying-$Leg"
        }
        Set-Prop $t 'claimedAt' $null
        return $t
    }

    if ($err) {
        Write-Audit @{ event = 'private-stamp-trigger-failed'; leg = $Leg; error = $err }
        $script:result.NotifyEvent = 'private-stamp-failed'
        $script:result.Transition = "$FromStatus -> failed"
    } else {
        Write-Audit @{ event = 'private-stamp-triggered'; leg = $Leg; runId = $run.runId; port = $run.port; artifactBranch = $run.artifactBranch }
        $script:result.Transition = "$FromStatus -> deploying-$Leg"
    }
    $script:result.Run = $runObj
    return $final
}

function Invoke-Poll {
    $st = Read-State
    $track = Get-Track $st
    if ($null -eq $track) { return $null }

    switch -Regex ($track.status) {
        '^inputs-ready$' {
            if ((Get-StepStatus $st 3) -eq 'completed') { return (Start-Leg 'last' 'inputs-ready') }
            return $track
        }
        '^triggering-(last|current)$' {
            $leg = $Matches[1]
            $claimedAt = if ($track.PSObject.Properties['claimedAt'] -and $track.claimedAt) { [datetime]$track.claimedAt } else { $null }
            if ($claimedAt -and ((Get-Date).ToUniversalTime() - $claimedAt.ToUniversalTime()).TotalMinutes -gt $StaleClaimMinutes) {
                $msg = "Queueing the '$leg' run was interrupted. Check pipeline $($script:Psu.id) for a run you did not expect, then use 'private-stamp retry'."
                $t = Update-Track {
                    param($cur, $s)
                    if ($cur.status -ne "triggering-$leg") { return $null }
                    $n = Copy-Track $cur
                    Set-Prop $n 'status' 'failed'; Set-Prop $n 'failedLeg' $leg; Set-Prop $n 'error' $msg; Set-Prop $n 'claimedAt' $null
                    return $n
                }
                Write-Audit @{ event = 'private-stamp-stale-claim'; leg = $leg }
                $script:result.NotifyEvent = 'private-stamp-failed'
                $script:result.Transition = "triggering-$leg -> failed"
                return $t
            }
            return $track
        }
        '^deploying-(last|current)$' {
            $leg = $Matches[1]
            $runId = $track.runs.$leg.runId
            $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
            $b = Invoke-RestMethod -Uri "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/build/builds/$($runId)?api-version=7.1" -Headers $headers -ErrorAction Stop
            if ($b.status -ne 'completed') { return $track }
            $ok = ($b.result -eq 'succeeded')
            $finishedAt = if ($b.finishTime) { ([datetime]$b.finishTime).ToUniversalTime().ToString('o') } else { Get-NowIso }
            $bResult = [string]$b.result
            $next = if (-not $ok) { 'failed' } elseif ($leg -eq 'last') { 'last-succeeded' } else { 'awaiting-bvt' }
            $t = Update-Track {
                param($cur, $s)
                if ($cur.status -ne "deploying-$leg") { return $null }
                $n = Copy-Track $cur
                $n.runs.$leg.status = 'completed'
                $n.runs.$leg.result = $bResult
                $n.runs.$leg.finishedAt = $finishedAt
                if ($next -eq 'failed') {
                    Set-Prop $n 'status' 'failed'; Set-Prop $n 'failedLeg' $leg
                    Set-Prop $n 'error' "Private stamp '$leg' deployment run $runId finished with result '$bResult'."
                } elseif ($next -eq 'last-succeeded') {
                    Set-Prop $n 'status' 'last-succeeded'
                } else {
                    Set-Prop $n 'status' 'awaiting-bvt'
                    Set-Prop $n 'bvtRequestedAt' (Get-NowIso)
                }
                return $n
            }
            Write-Audit @{ event = 'private-stamp-run-completed'; leg = $leg; runId = $runId; result = $bResult }
            if ($next -eq 'failed') {
                $script:result.NotifyEvent = 'private-stamp-failed'
                $script:result.Transition = "deploying-$leg -> failed"
                return $t
            }
            if ($next -eq 'awaiting-bvt') {
                $script:result.NotifyEvent = 'private-stamp-bvt-ready'
                $script:result.Transition = 'deploying-current -> awaiting-bvt'
                return $t
            }
            return (Start-Leg 'current' 'last-succeeded')
        }
        '^last-succeeded$' {
            # Leg "last" succeeded but queueing "current" did not complete in the same tick.
            return (Start-Leg 'current' 'last-succeeded')
        }
        default { return $track }
    }
}

try {
    # --- Resolve paths + config ---
    if (-not $StateFile -or -not $StateLock -or -not $AuditFile -or -not $ReleaseFile) {
        $paths = & (Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1') -ReleaseId $ReleaseId
        if (-not $StateFile)   { $StateFile = $paths.StateFile }
        if (-not $StateLock)   { $StateLock = $paths.LockFile }
        if (-not $AuditFile)   { $AuditFile = $paths.AuditFile }
        if (-not $ReleaseFile) { $ReleaseFile = $paths.ReleaseFile }
    }
    $script:StateFile = $StateFile; $script:StateLock = $StateLock
    $script:AuditFile = $AuditFile; $script:ReleaseFile = $ReleaseFile
    $script:AccessToken = $AccessToken
    if (-not (Test-Path -LiteralPath $StateFile)) { throw "State file not found: $StateFile" }

    if (-not $PipelineCatalogPath) { $PipelineCatalogPath = Join-Path $PSScriptRoot '..\pipeline-catalog.json' }
    $catalog = Get-Content -LiteralPath $PipelineCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $psuProp = $catalog.PSObject.Properties['privateStampUpgrade']
    if (-not $psuProp -or -not $psuProp.Value -or $psuProp.Value.enabled -ne $true) {
        # Feature off: nothing to do (Step 13 join treats a missing track as satisfied).
        $result.Success = $true
        $result.Status = 'disabled'
        return $result
    }
    $script:Psu = $psuProp.Value
    if (-not $Psu.id) { throw "pipeline-catalog.json → privateStampUpgrade.id is required when enabled." }

    if (-not $Organization -or -not $Project) {
        if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
        $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Organization) { $Organization = $svc.ado.organization }
        if (-not $Project) { $Project = $svc.ado.project }
    }
    $script:Organization = $Organization; $script:Project = $Project

    $track = $null
    switch ($Action) {
        'Get' {
            $track = Get-Track (Read-State)
        }
        'Init' {
            $testMode = $false
            if (Test-Path -LiteralPath $ReleaseFile) { $testMode = [bool](Get-Release).testMode }
            $script:psuCreated = $false
            $track = Update-Track {
                param($cur, $st)
                if ($null -ne $cur) { return $null }
                $script:psuCreated = $true
                if ($testMode) {
                    return [pscustomobject]@{ status = 'skipped'; skipReason = 'test-mode'; skippedAt = (Get-NowIso); skippedBy = 'zed'; runs = [pscustomobject]@{} }
                }
                return [pscustomobject]@{ status = 'awaiting-input'; requestedAt = (Get-NowIso); runs = [pscustomobject]@{} }
            }
            if ($script:psuCreated -and $track.status -eq 'awaiting-input') {
                $result.NotifyEvent = 'private-stamp-input-needed'
                $result.Transition = 'none -> awaiting-input'
                Write-Audit @{ event = 'private-stamp-input-requested' }
            } elseif ($script:psuCreated) {
                $result.Transition = 'none -> skipped (test-mode)'
            } else {
                # Inputs may have been supplied before Step 5 — start now if possible.
                $track = Invoke-Poll
            }
        }
        'SetInputs' {
            $errors = @()
            if ($Instance -notmatch '^[A-Za-z0-9]{1,8}$') { $errors += "Instance '$Instance' must be 1-8 letters/digits (e.g. A)." }
            foreach ($p in @(@{ n = 'LastPort'; v = $LastPort }, @{ n = 'CurrentPort'; v = $CurrentPort })) {
                if ($p.v -lt 1024 -or $p.v -gt 65534) { $errors += "$($p.n) $($p.v) must be between 1024 and 65534." }
            }
            $span = Get-PortSpan
            if ([math]::Abs($LastPort - $CurrentPort) -lt $span) {
                $errors += "LastPort $LastPort and CurrentPort $CurrentPort overlap (each deployment uses $span consecutive port(s))."
            }
            if ($QueueName -notmatch '^[A-Za-z0-9._-]{1,128}$') { $errors += "TeeWorkflowQueueName '$QueueName' may only contain letters, digits, '.', '_' and '-'." }
            if ($LastArtifactBranch -notmatch '^[A-Za-z0-9._/-]{1,200}$') { $errors += "Last build branch '$LastArtifactBranch' is not a valid branch name." }
            $rel = Get-Release
            $currentBranch = [string]$rel.currentBranch
            if (-not $currentBranch) { $errors += "release.json has no currentBranch." }
            if ($LastArtifactBranch -and $currentBranch -and $LastArtifactBranch -ieq $currentBranch) {
                $errors += "Last build branch equals this release's branch ($currentBranch) — the upgrade test needs the PREVIOUS build."
            }
            if ($errors.Count -gt 0) { throw ("Invalid private stamp inputs:`n - " + ($errors -join "`n - ")) }

            $tmpl = if ($Psu.PSObject.Properties['serviceOverrideSettingsTemplate'] -and $Psu.serviceOverrideSettingsTemplate) { [string]$Psu.serviceOverrideSettingsTemplate } else { '@{}' }
            $inputs = [pscustomobject]@{
                instance                = $Instance.ToUpperInvariant()
                lastPort                = $LastPort
                currentPort             = $CurrentPort
                lastArtifactBranch      = $LastArtifactBranch
                currentArtifactBranch   = $currentBranch
                queueName               = $QueueName
                serviceOverrideSettings = $tmpl.Replace('{queueName}', $QueueName)
                providedAt              = (Get-NowIso)
                providedBy              = $By
            }
            $rejected = $null
            $track = Update-Track {
                param($cur, $st)
                $allowed = @('awaiting-input', 'inputs-ready', 'failed')
                if ($null -ne $cur -and $allowed -notcontains [string]$cur.status) { return $null }
                $t = if ($null -eq $cur) { [pscustomobject]@{ requestedAt = (Get-NowIso) } } else { Copy-Track $cur }
                Set-Prop $t 'status' 'inputs-ready'
                Set-Prop $t 'inputs' $inputs
                Set-Prop $t 'runs' ([pscustomobject]@{})
                Set-Prop $t 'failedLeg' $null
                Set-Prop $t 'error' $null
                return $t
            }
            if ($track.status -ne 'inputs-ready') {
                throw "Private stamp inputs can't be changed while the track is '$($track.status)'. Use 'private-stamp retry' / 'private-stamp skip' instead."
            }
            Write-Audit @{ event = 'private-stamp-inputs'; instance = $inputs.instance; lastPort = $LastPort; currentPort = $CurrentPort; lastArtifactBranch = $LastArtifactBranch; queueName = $QueueName; by = $By }
            $result.Transition = 'inputs-ready'
            $track = Invoke-Poll
        }
        'Poll' {
            $track = Invoke-Poll
        }
        'Retry' {
            $st = Read-State
            $cur = Get-Track $st
            if ($null -eq $cur -or $cur.status -ne 'failed' -or -not $cur.failedLeg) {
                throw "Nothing to retry — private stamp track is '$(if ($cur) { $cur.status } else { 'not started' })'."
            }
            $leg = [string]$cur.failedLeg
            $from = "retry-$leg"
            $null = Update-Track {
                param($c, $s)
                if ($c.status -ne 'failed') { return $null }
                $t = Copy-Track $c
                Set-Prop $t 'status' $from
                return $t
            }
            Write-Audit @{ event = 'private-stamp-retry'; leg = $leg; by = $By }
            $track = Start-Leg $leg $from
        }
        'SignOff' {
            $track = Update-Track {
                param($cur, $st)
                if ($null -eq $cur -or $cur.status -ne 'awaiting-bvt') { return $null }
                $t = Copy-Track $cur
                Set-Prop $t 'status' 'signed-off'
                Set-Prop $t 'signedOffAt' (Get-NowIso)
                Set-Prop $t 'signedOffBy' $By
                return $t
            }
            if ($null -eq $track -or $track.status -ne 'signed-off') {
                throw "Private stamp BVT sign-off is only possible in 'awaiting-bvt' (current: '$(if ($track) { $track.status } else { 'not started' })')."
            }
            Write-Audit @{ event = 'private-stamp-signed-off'; by = $By }
            $result.Transition = 'awaiting-bvt -> signed-off'
        }
        'Skip' {
            $track = Update-Track {
                param($cur, $st)
                if ($null -ne $cur -and @('signed-off', 'skipped') -contains [string]$cur.status) { return $null }
                $t = if ($null -eq $cur) { [pscustomobject]@{ runs = [pscustomobject]@{} } } else { Copy-Track $cur }
                Set-Prop $t 'previousStatus' $(if ($cur) { $cur.status } else { $null })
                Set-Prop $t 'status' 'skipped'
                Set-Prop $t 'skippedAt' (Get-NowIso)
                Set-Prop $t 'skippedBy' $By
                Set-Prop $t 'skipReason' $Reason
                return $t
            }
            Write-Audit @{ event = 'private-stamp-skipped'; by = $By; reason = $Reason }
            $result.Transition = 'skipped'
        }
    }

    if ($null -eq $track) { $track = Get-Track (Read-State) }
    $result.Track = $track
    $result.Status = if ($track) { [string]$track.status } else { $null }
    $result.Success = $true
} catch {
    $result.Error = $_.Exception.Message
    try { $result.Track = Get-Track (Read-State); if ($result.Track) { $result.Status = [string]$result.Track.status } } catch { }
    if ($Action -ne 'Poll') { throw }
    Write-Audit @{ event = 'private-stamp-poll-error'; error = $_.Exception.Message }
}

return $result
