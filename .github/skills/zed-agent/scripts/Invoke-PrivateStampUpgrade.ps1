<#
.SYNOPSIS
    Private stamp upgrade test — side track that runs in parallel with the canary steps
    (kicked off at Step 5, joined at Step 13). Enabled by
    pipeline-catalog.json → privateStampUpgrade.enabled.

.DESCRIPTION
    Deploys two builds side by side to one private stamp instance using the private stamp
    pipeline (CONFIG[pipelines.privateStampUpgrade.id]) — both legs are queued AT THE SAME TIME:

        leg "last"    : ArtifactBranch = <owner-supplied last build branch>, port = LastPort
        leg "current" : ArtifactBranch = release.currentBranch (this release's build), port = CurrentPort

    Both legs get the same ServiceOverrideSettings, built from
    privateStampUpgrade.serviceOverrideSettingsTemplate with {queueName} = the owner-supplied
    TeeWorkflowQueueName. When BOTH legs succeed and privateStampUpgrade.bvtRelease is configured,
    ZED creates a release of the classic BVT release definition with
    <bvtRelease.vaultIdVariable> (e.g. PrivateStampVaultId) = the owner-supplied redirected vault
    ARM id, and the latest version of every artifact passed explicitly. When the BVT stage
    (bvtRelease.environmentName) finishes, the track waits for the owner's sign-off
    (`approve-private-stamp`). Step 13 does not start until the track is signed-off or skipped.

    State lives in state.json → privateStampUpgrade:
        status : awaiting-input | inputs-ready | triggering | deploying | triggering-bvt |
                 bvt-running | awaiting-bvt | signed-off | skipped | failed
        inputs : { instance, lastPort, currentPort, lastArtifactBranch, currentArtifactBranch,
                   queueName, serviceOverrideSettings, vaultId, providedAt, providedBy }
        runs   : { last: {...}, current: {...}, bvt: {...} }
        failedLegs (subset of last, current, bvt), error, requestedAt, bvtOutcome,
        signedOffAt, signedOffBy, skippedAt, skippedBy, skipReason

    Actions:
        Init      Step 5 kick-off. Creates the track (awaiting-input) and returns
                  NotifyEvent 'private-stamp-input-needed'. No-op if it already exists.
                  In test mode the track is created as 'skipped' (no human input, no wait).
        SetInputs Owner's `private-stamp` command. Validates + stores the inputs, then behaves
                  like Poll (queues both legs once Step 3 has completed).
        Poll      Watcher / cold-resume side-channel, every tick: queues the legs, tracks them,
                  starts the BVT release when both succeeded, tracks the BVT stage. Never
                  throws — errors are returned in .Error.
        Retry     Re-runs only what failed: the failed leg(s), or the BVT release.
        SignOff   Owner's sign-off (awaiting-bvt, or failed with only the BVT failed → owner override).
        Skip      Owner skips the track (Step 13 join is released).
        Get       Returns the current track state.

    Every trigger is "claimed" under the state lock (status triggering / triggering-bvt) before
    the POST, so the watcher and an owner command can never double-queue.

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
    [string]$VaultId,
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

$script:Legs = @('last', 'current')
$script:VaultIdPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.RecoveryServices/vaults/[^/]+$'

function Get-NowIso { (Get-Date).ToUniversalTime().ToString('o') }

function Write-Audit([hashtable]$Entry) {
    try {
        $Entry.ts = (Get-NowIso)
        $Entry | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $script:AuditFile -Encoding UTF8
    } catch { <# audit is best-effort #> }
}

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

function Get-RunsObj($Track) {
    if (-not $Track.PSObject.Properties['runs'] -or $null -eq $Track.runs) { Set-Prop $Track 'runs' ([pscustomobject]@{}) }
    return $Track.runs
}

function Get-Run($Track, [string]$Leg) {
    if ($Track.PSObject.Properties['runs'] -and $Track.runs -and $Track.runs.PSObject.Properties[$Leg]) { return $Track.runs.$Leg }
    return $null
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

function Get-BvtConfig {
    $p = $script:Psu.PSObject.Properties['bvtRelease']
    if ($p -and $p.Value -and $p.Value.definitionId) { return $p.Value }
    return $null
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

function Set-Failed($Track, [string[]]$FailedLegs, [string]$Message) {
    Set-Prop $Track 'status' 'failed'
    Set-Prop $Track 'failedLegs' @($FailedLegs)
    Set-Prop $Track 'error' $Message
    Set-Prop $Track 'claimedAt' $null
}

# Queues the given legs IN PARALLEL (one claim, then one POST per leg). Returns the persisted track.
function Start-Deployments([string]$FromStatus, [string[]]$Legs) {
    $claimed = Update-Track {
        param($cur, $st)
        if ($null -eq $cur -or $cur.status -ne $FromStatus) { return $null }
        $t = Copy-Track $cur
        Set-Prop $t 'status' 'triggering'
        Set-Prop $t 'claimedAt' (Get-NowIso)
        Set-Prop $t 'error' $null
        return $t
    }
    if ($null -eq $claimed -or $claimed.status -ne 'triggering') { return $null }

    $ref = Get-SourceRef $claimed
    $orgBase = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis"
    $newRuns = @{}
    $queueErrors = @{}
    foreach ($leg in $Legs) {
        $tp = New-TemplateParameters $claimed $leg
        $tpObj = New-Object PSObject
        foreach ($k in $tp.Keys) { $tpObj | Add-Member -MemberType NoteProperty -Name $k -Value $tp[$k] }
        $body = [pscustomobject]@{
            resources          = [pscustomobject]@{ repositories = [pscustomobject]@{ self = [pscustomobject]@{ refName = $ref } } }
            templateParameters = $tpObj
        } | ConvertTo-Json -Depth 8
        $run = [ordered]@{
            leg = $leg; pipelineId = [int]$script:Psu.id; sourceBranch = $ref
            artifactBranch = $tp[(Get-ParamName 'artifactBranch' 'ArtifactBranch')]
            port = [int]$tp[(Get-ParamName 'port' 'WebRolePort')]
            templateParameters = [pscustomobject]$tp
            runId = $null; url = $null; status = $null; result = $null; queuedAt = (Get-NowIso); finishedAt = $null
        }
        try {
            $headers = @{ Authorization = "Bearer $(Get-AdoToken)"; 'Content-Type' = 'application/json' }
            $resp = Invoke-RestMethod -Uri "$orgBase/pipelines/$($script:Psu.id)/runs?api-version=7.1" -Method POST -Headers $headers -Body $body -ErrorAction Stop
            $run.runId = $resp.id
            $run.url = "https://dev.azure.com/$($script:Organization)/$($script:Project)/_build/results?buildId=$($resp.id)"
            $run.status = 'inProgress'
            Write-Audit @{ event = 'private-stamp-triggered'; leg = $leg; runId = $run.runId; port = $run.port; artifactBranch = $run.artifactBranch }
        } catch {
            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { '' }
            $queueErrors[$leg] = "Failed to queue private stamp '$leg' run: $($_.Exception.Message)$detail"
            $run.status = 'queue-failed'; $run.result = 'failed'; $run.finishedAt = (Get-NowIso)
            Write-Audit @{ event = 'private-stamp-trigger-failed'; leg = $leg; error = $queueErrors[$leg] }
        }
        $newRuns[$leg] = [pscustomobject]$run
    }

    $allFailed = $queueErrors.Count -eq $Legs.Count
    $final = Update-Track {
        param($cur, $st)
        $t = Copy-Track $cur
        $runs = Get-RunsObj $t
        foreach ($leg in $newRuns.Keys) { Set-Prop $runs $leg $newRuns[$leg] }
        if ($runs.PSObject.Properties['bvt']) { $runs.PSObject.Properties.Remove('bvt') }
        if ($allFailed) { Set-Failed $t @($queueErrors.Keys) (($queueErrors.Values) -join ' ') }
        else { Set-Prop $t 'status' 'deploying'; Set-Prop $t 'failedLegs' @(); Set-Prop $t 'claimedAt' $null }
        return $t
    }
    if ($allFailed) {
        $script:result.NotifyEvent = 'private-stamp-failed'
        $script:result.Transition = "$FromStatus -> failed"
    } else {
        $script:result.Transition = "$FromStatus -> deploying ($($Legs -join ' + '))"
    }
    $script:result.Run = [pscustomobject]$newRuns
    return $final
}

# Creates the BVT release (classic Release pipeline) with the vault id override. Returns the persisted track.
function Start-Bvt([string]$FromStatus) {
    $bvt = Get-BvtConfig
    $claimed = Update-Track {
        param($cur, $st)
        if ($null -eq $cur -or $cur.status -ne $FromStatus) { return $null }
        $t = Copy-Track $cur
        Set-Prop $t 'status' 'triggering-bvt'
        Set-Prop $t 'claimedAt' (Get-NowIso)
        Set-Prop $t 'error' $null
        return $t
    }
    if ($null -eq $claimed -or $claimed.status -ne 'triggering-bvt') { return $null }

    $vsrm = "https://vsrm.dev.azure.com/$($script:Organization)/$($script:Project)/_apis/release"
    $varName = if ($bvt.vaultIdVariable) { [string]$bvt.vaultIdVariable } else { 'PrivateStampVaultId' }
    $run = [ordered]@{ leg = 'bvt'; definitionId = [int]$bvt.definitionId; releaseId = $null; name = $null; url = $null; status = $null; environmentStatus = $null; artifacts = @(); createdAt = (Get-NowIso); finishedAt = $null }
    $err = $null
    try {
        $headers = @{ Authorization = "Bearer $(Get-AdoToken)"; 'Content-Type' = 'application/json' }
        # Pass every artifact's default (latest) version explicitly — the portal does the same; an
        # unresolved artifact would start the release without bits.
        $versions = Invoke-RestMethod -Uri "$vsrm/artifacts/versions?releaseDefinitionId=$($bvt.definitionId)&api-version=7.1" -Headers $headers -ErrorAction Stop
        $artifacts = @()
        foreach ($av in @($versions.artifactVersions)) {
            if ($av.errorMessage) { throw "BVT artifact '$($av.alias)': $($av.errorMessage)" }
            if (-not $av.defaultVersion -or -not $av.defaultVersion.id) { throw "BVT artifact '$($av.alias)' has no version to deploy." }
            $artifacts += [pscustomobject]@{ alias = $av.alias; instanceReference = [pscustomobject]@{ id = [string]$av.defaultVersion.id; name = [string]$av.defaultVersion.name } }
        }
        $vars = [ordered]@{}
        if ($bvt.PSObject.Properties['variables'] -and $bvt.variables) {
            foreach ($p in $bvt.variables.PSObject.Properties) { $vars[$p.Name] = [pscustomobject]@{ value = [string]$p.Value } }
        }
        $vars[$varName] = [pscustomobject]@{ value = [string]$claimed.inputs.vaultId }
        $desc = "ZED private stamp upgrade BVT — release $ReleaseId, instance $($claimed.inputs.instance), ports $($claimed.inputs.lastPort)/$($claimed.inputs.currentPort)"
        $body = [pscustomobject]@{ definitionId = [int]$bvt.definitionId; isDraft = $false; description = $desc; artifacts = $artifacts; variables = [pscustomobject]$vars } | ConvertTo-Json -Depth 8
        $rel = Invoke-RestMethod -Uri "$vsrm/releases?api-version=7.1" -Method POST -Headers $headers -Body $body -ErrorAction Stop
        $run.releaseId = $rel.id; $run.name = $rel.name; $run.status = [string]$rel.status
        $run.url = if ($rel._links -and $rel._links.web -and $rel._links.web.href) { [string]$rel._links.web.href } else { "https://dev.azure.com/$($script:Organization)/$($script:Project)/_releaseProgress?_a=release-pipeline-progress&releaseId=$($rel.id)" }
        $run.artifacts = @($artifacts | ForEach-Object { "$($_.alias)=$($_.instanceReference.name)" })
        Write-Audit @{ event = 'private-stamp-bvt-triggered'; releaseId = $rel.id; name = $rel.name; vaultVariable = $varName; artifacts = $run.artifacts }
    } catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { '' }
        $err = "Failed to start the BVT release (definition $($bvt.definitionId)): $($_.Exception.Message)$detail"
        Write-Audit @{ event = 'private-stamp-bvt-trigger-failed'; error = $err }
    }
    $runObj = [pscustomobject]$run
    $final = Update-Track {
        param($cur, $st)
        $t = Copy-Track $cur
        Set-Prop (Get-RunsObj $t) 'bvt' $runObj
        if ($err) { Set-Failed $t @('bvt') $err }
        else { Set-Prop $t 'status' 'bvt-running'; Set-Prop $t 'failedLegs' @(); Set-Prop $t 'claimedAt' $null }
        return $t
    }
    if ($err) {
        $script:result.NotifyEvent = 'private-stamp-failed'
        $script:result.Transition = "$FromStatus -> failed (bvt)"
    } else {
        $script:result.Transition = "$FromStatus -> bvt-running"
    }
    $script:result.Run = $runObj
    return $final
}

function Complete-Deployments($Track) {
    # Both legs done (success or failure). Succeeded -> BVT release (or owner sign-off when no BVT configured).
    $failed = @($script:Legs | Where-Object { (Get-Run $Track $_).result -ne 'succeeded' })
    if ($failed.Count -gt 0) {
        $msgs = @($failed | ForEach-Object { $r = Get-Run $Track $_; "Private stamp '$_' deployment $(if ($r.runId) { "run $($r.runId) " })finished with result '$($r.result)'." })
        $t = Update-Track {
            param($cur, $s)
            if ($cur.status -ne 'deploying') { return $null }
            $n = Copy-Track $cur; Set-Failed $n $failed ($msgs -join ' '); return $n
        }
        $script:result.NotifyEvent = 'private-stamp-failed'
        $script:result.Transition = "deploying -> failed ($($failed -join ', '))"
        return $t
    }
    if (Get-BvtConfig) { return (Start-Bvt 'deploying') }
    $t = Update-Track {
        param($cur, $s)
        if ($cur.status -ne 'deploying') { return $null }
        $n = Copy-Track $cur; Set-Prop $n 'status' 'awaiting-bvt'; Set-Prop $n 'bvtRequestedAt' (Get-NowIso); return $n
    }
    $script:result.NotifyEvent = 'private-stamp-bvt-ready'
    $script:result.Transition = 'deploying -> awaiting-bvt'
    return $t
}

function Invoke-Poll {
    $st = Read-State
    $track = Get-Track $st
    if ($null -eq $track) { return $null }

    switch -Regex ($track.status) {
        '^inputs-ready$' {
            if ((Get-StepStatus $st 3) -eq 'completed') { return (Start-Deployments 'inputs-ready' $script:Legs) }
            return $track
        }
        '^(triggering|triggering-bvt|retrying)$' {
            $what = $Matches[1]
            $claimedAt = if ($track.PSObject.Properties['claimedAt'] -and $track.claimedAt) { [datetime]$track.claimedAt } else { $null }
            if ($claimedAt -and ((Get-Date).ToUniversalTime() - $claimedAt.ToUniversalTime()).TotalMinutes -gt $StaleClaimMinutes) {
                $legs = if ($what -eq 'triggering-bvt') { @('bvt') } elseif ($what -eq 'retrying' -and $track.PSObject.Properties['failedLegs'] -and @($track.failedLegs).Count) { @($track.failedLegs) } else { $script:Legs }
                $where = if ($what -eq 'triggering-bvt') { "release definition $((Get-BvtConfig).definitionId)" } else { "pipeline $($script:Psu.id)" }
                $msg = "Queueing was interrupted. Check $where for a run you did not expect, then use 'private-stamp retry'."
                $t = Update-Track {
                    param($cur, $s)
                    if ($cur.status -ne $what) { return $null }
                    $n = Copy-Track $cur; Set-Failed $n $legs $msg; return $n
                }
                Write-Audit @{ event = 'private-stamp-stale-claim'; status = $what }
                $script:result.NotifyEvent = 'private-stamp-failed'
                $script:result.Transition = "$what -> failed"
                return $t
            }
            return $track
        }
        '^deploying$' {
            $updates = @{}
            foreach ($leg in $script:Legs) {
                $r = Get-Run $track $leg
                if (-not $r -or $r.status -ne 'inProgress' -or -not $r.runId) { continue }
                $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
                $b = Invoke-RestMethod -Uri "https://dev.azure.com/$($script:Organization)/$($script:Project)/_apis/build/builds/$($r.runId)?api-version=7.1" -Headers $headers -ErrorAction Stop
                if ($b.status -ne 'completed') { continue }
                $updates[$leg] = @{ result = [string]$b.result; finishedAt = $(if ($b.finishTime) { ([datetime]$b.finishTime).ToUniversalTime().ToString('o') } else { Get-NowIso }) }
                Write-Audit @{ event = 'private-stamp-run-completed'; leg = $leg; runId = $r.runId; result = [string]$b.result }
            }
            if ($updates.Count -gt 0) {
                $track = Update-Track {
                    param($cur, $s)
                    if ($cur.status -ne 'deploying') { return $null }
                    $n = Copy-Track $cur
                    foreach ($leg in $updates.Keys) {
                        $n.runs.$leg.status = 'completed'; $n.runs.$leg.result = $updates[$leg].result; $n.runs.$leg.finishedAt = $updates[$leg].finishedAt
                    }
                    return $n
                }
            }
            $pending = @($script:Legs | Where-Object { $r = Get-Run $track $_; -not $r -or $r.status -eq 'inProgress' })
            if ($track.status -eq 'deploying' -and $pending.Count -eq 0) { return (Complete-Deployments $track) }
            return $track
        }
        '^bvt-running$' {
            $bvt = Get-BvtConfig
            $r = Get-Run $track 'bvt'
            $headers = @{ Authorization = "Bearer $(Get-AdoToken)" }
            $rel = Invoke-RestMethod -Uri "https://vsrm.dev.azure.com/$($script:Organization)/$($script:Project)/_apis/release/releases/$($r.releaseId)?api-version=7.1" -Headers $headers -ErrorAction Stop
            $envName = if ($bvt.environmentName) { [string]$bvt.environmentName } else { $null }
            $envs = @($rel.environments)
            $target = if ($envName) { @($envs | Where-Object { $_.name -eq $envName })[0] } else { $envs | Sort-Object rank | Select-Object -Last 1 }
            if (-not $target) { throw "BVT release $($r.releaseId) has no stage named '$envName'." }
            $envStatus = [string]$target.status
            $stopped = @($envs | Where-Object { $_.status -in @('rejected', 'canceled') }).Count -gt 0 -and $envStatus -in @('notStarted', 'undefined')
            $done = $envStatus -in @('succeeded', 'partiallySucceeded', 'rejected', 'canceled') -or $rel.status -eq 'abandoned' -or $stopped
            if (-not $done) { return $track }
            $summary = ($envs | Sort-Object rank | ForEach-Object { "$($_.name)=$($_.status)" }) -join '; '
            $passed = $envStatus -in @('succeeded', 'partiallySucceeded')
            $t = Update-Track {
                param($cur, $s)
                if ($cur.status -ne 'bvt-running') { return $null }
                $n = Copy-Track $cur
                $n.runs.bvt.status = 'completed'; $n.runs.bvt.environmentStatus = $envStatus; $n.runs.bvt.finishedAt = (Get-NowIso)
                Set-Prop $n.runs.bvt 'stages' $summary
                Set-Prop $n 'bvtOutcome' $envStatus
                if ($passed) { Set-Prop $n 'status' 'awaiting-bvt'; Set-Prop $n 'bvtRequestedAt' (Get-NowIso) }
                else { Set-Failed $n @('bvt') "BVT release $($r.name) ended with '$envStatus' ($summary)." }
                return $n
            }
            Write-Audit @{ event = 'private-stamp-bvt-completed'; releaseId = $r.releaseId; stage = $envStatus; stages = $summary }
            $script:result.NotifyEvent = if ($passed) { 'private-stamp-bvt-ready' } else { 'private-stamp-failed' }
            $script:result.Transition = "bvt-running -> $(if ($passed) { 'awaiting-bvt' } else { 'failed (bvt)' })"
            return $t
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
            $VaultId = ([string]$VaultId).Trim()
            if (Get-BvtConfig) {
                if ($VaultId -notmatch $script:VaultIdPattern) {
                    $errors += "Redirected vault '$VaultId' must be a Recovery Services vault ARM id: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.RecoveryServices/vaults/<name>."
                }
            } elseif ($VaultId -and $VaultId -notmatch $script:VaultIdPattern) {
                $errors += "Redirected vault '$VaultId' is not a Recovery Services vault ARM id."
            }
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
                vaultId                 = $(if ($VaultId) { $VaultId } else { $null })
                providedAt              = (Get-NowIso)
                providedBy              = $By
            }
            $track = Update-Track {
                param($cur, $st)
                $allowed = @('awaiting-input', 'inputs-ready', 'failed')
                if ($null -ne $cur -and $allowed -notcontains [string]$cur.status) { return $null }
                $t = if ($null -eq $cur) { [pscustomobject]@{ requestedAt = (Get-NowIso) } } else { Copy-Track $cur }
                Set-Prop $t 'status' 'inputs-ready'
                Set-Prop $t 'inputs' $inputs
                Set-Prop $t 'runs' ([pscustomobject]@{})
                Set-Prop $t 'failedLegs' @()
                Set-Prop $t 'error' $null
                return $t
            }
            if ($track.status -ne 'inputs-ready') {
                throw "Private stamp inputs can't be changed while the track is '$($track.status)'. Use 'private-stamp retry' / 'private-stamp skip' instead."
            }
            Write-Audit @{ event = 'private-stamp-inputs'; instance = $inputs.instance; lastPort = $LastPort; currentPort = $CurrentPort; lastArtifactBranch = $LastArtifactBranch; queueName = $QueueName; vaultId = $inputs.vaultId; by = $By }
            $result.Transition = 'inputs-ready'
            $track = Invoke-Poll
        }
        'Poll' {
            $track = Invoke-Poll
        }
        'Retry' {
            $cur = Get-Track (Read-State)
            $failedLegs = if ($cur -and $cur.PSObject.Properties['failedLegs']) { @($cur.failedLegs | Where-Object { $_ }) } else { @() }
            if ($null -eq $cur -or $cur.status -ne 'failed' -or $failedLegs.Count -eq 0) {
                throw "Nothing to retry — private stamp track is '$(if ($cur) { $cur.status } else { 'not started' })'."
            }
            $from = 'retrying'
            $null = Update-Track {
                param($c, $s)
                if ($c.status -ne 'failed') { return $null }
                $t = Copy-Track $c; Set-Prop $t 'status' $from; Set-Prop $t 'claimedAt' (Get-NowIso); return $t
            }
            Write-Audit @{ event = 'private-stamp-retry'; legs = $failedLegs; by = $By }
            if ($failedLegs -contains 'bvt') { $track = Start-Bvt $from }
            else { $track = Start-Deployments $from @($failedLegs | Where-Object { $script:Legs -contains $_ }) }
        }
        'SignOff' {
            $track = Update-Track {
                param($cur, $st)
                if ($null -eq $cur) { return $null }
                $onlyBvtFailed = $cur.status -eq 'failed' -and @($cur.failedLegs).Count -eq 1 -and @($cur.failedLegs)[0] -eq 'bvt' -and (Get-Run $cur 'bvt') -and (Get-Run $cur 'bvt').releaseId
                if ($cur.status -ne 'awaiting-bvt' -and -not $onlyBvtFailed) { return $null }
                $t = Copy-Track $cur
                Set-Prop $t 'status' 'signed-off'
                Set-Prop $t 'signedOffAt' (Get-NowIso)
                Set-Prop $t 'signedOffBy' $By
                if ($onlyBvtFailed) { Set-Prop $t 'signedOffDespiteBvt' $cur.bvtOutcome }
                return $t
            }
            if ($null -eq $track -or $track.status -ne 'signed-off') {
                throw "Private stamp sign-off is only possible once the BVT has run (current: '$(if ($track) { $track.status } else { 'not started' })')."
            }
            Write-Audit @{ event = 'private-stamp-signed-off'; by = $By; bvtOutcome = $track.bvtOutcome }
            $result.Transition = 'signed-off'
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
