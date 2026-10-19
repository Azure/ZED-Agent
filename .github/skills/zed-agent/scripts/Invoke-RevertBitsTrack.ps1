<#
.SYNOPSIS
    Revert bits side track (service-config.json → revertBits.prepareDuringCanaryBvt): finishes the
    revert build WHILE the canary BVT (Step 6) runs, so Step 7 can roll canary back with it right
    after `approve-bvt`.

.DESCRIPTION
    The agent does 7a (Plan → owner picks settings) and 7b (Prepare + PR) at Step 6 entry, as in
    step-behaviors.md → Step 7 — Revert bits, but arms NO watcher directive (the primary one is
    busy with the BVT releases / timer). This script carries state.revertBits on from there —
    pure REST/git, called by the watcher and cold resume on every tick:

      pr-open      PR merged → 'queue-build' (prMergedAt); abandoned → 'failed'
      queue-build  Resolve-ReleaseBuild DeployCommit on the revert branch: reuse the official build
                   CI started for the merge; none yet → wait up to -CiGraceMinutes after the merge,
                   then QueueBuild pinned to that commit → 'building'. (The agent sets
                   'queue-build' itself when Prepare returned 'no-config-changes'.)
      building     build succeeded → 'ready' (NotifyEvent revert-bits-ready); failed/canceled →
                   'failed' (revert-bits-failed)

    'ready' is a valid rollback source: Step 7 deploys it (pinned to buildId) and Step 8 runs the
    BVT on it — no separate owner BVT (`approve-revert`) in this mode.

    Actions: Poll (never throws), Get.

.OUTPUTS
    PSCustomObject: Success, Action, Phase, Transition, NotifyEvent, RevertBits, Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Poll', 'Get')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$StateFile,
    [string]$StateLock,
    [string]$AuditFile,
    [string]$ReleaseFile,
    [string]$ServiceConfigPath,
    [string]$RepoPath = (Get-Location).Path,
    [string]$AccessToken,
    [int]$CiGraceMinutes = 10,
    # Tests point this at a stub; defaults to the real script.
    [string]$ResolveBuildScript = (Join-Path $PSScriptRoot 'Resolve-ReleaseBuild.ps1'),
    [datetime]$Now
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

$out = [pscustomobject]@{ Success = $false; Action = $Action; Phase = $null; Transition = $null; NotifyEvent = $null; RevertBits = $null; Error = $null }
$cfj = @{ AsHashtable = $true; Depth = 100 }
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $cfj.DateKind = 'String' }

function Get-UtcNow { if ($script:NowValue) { $script:NowValue } else { (Get-Date).ToUniversalTime() } }
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
function ConvertTo-UtcDate($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { if ($v.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc) }; return $v.ToUniversalTime() }
    return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}
function Get-RevertBits {
    $st = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json @cfj
    if ($st.ContainsKey('revertBits')) { return $st['revertBits'] }
    return $null
}
# Applies $Fields to state.revertBits only if its phase is still $FromPhase (another writer — the
# agent or a concurrent tick — may have moved it). Returns $true when written.
function Set-RevertBits([string]$FromPhase, [hashtable]$Fields) {
    $script:wrote = $false
    Invoke-WithStateLock -LockFile $script:StateLock -Action ({
        $st = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json @cfj
        $rb = $st['revertBits']
        if (-not $rb -or [string]$rb['phase'] -ne $FromPhase) { return }
        foreach ($k in $Fields.Keys) { $rb[$k] = $Fields[$k] }
        $st['lastUpdated'] = Get-NowIso
        $st | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 -NoNewline
        $script:wrote = $true
    })
    return $script:wrote
}

try {
    if ($PSBoundParameters.ContainsKey('Now')) { $script:NowValue = $Now.ToUniversalTime() }
    if (-not $StateFile -or -not $StateLock -or -not $AuditFile -or -not $ReleaseFile) {
        $paths = & (Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1') -ReleaseId $ReleaseId
        if (-not $StateFile) { $StateFile = $paths.StateFile }
        if (-not $StateLock) { $StateLock = $paths.LockFile }
        if (-not $AuditFile) { $AuditFile = $paths.AuditFile }
        if (-not $ReleaseFile) { $ReleaseFile = $paths.ReleaseFile }
    }
    $script:StateFile = $StateFile; $script:StateLock = $StateLock; $script:AuditFile = $AuditFile; $script:AccessToken = $AccessToken
    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $release = if (Test-Path -LiteralPath $ReleaseFile) { Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $rbCfg = $svc.revertBits
    $early = $rbCfg -and $rbCfg.enabled -eq $true -and $rbCfg.PSObject.Properties['prepareDuringCanaryBvt'] -and $rbCfg.prepareDuringCanaryBvt -eq $true

    $rb = Get-RevertBits
    $phase = if ($rb) { [string]$rb['phase'] } else { $null }
    if ($Action -eq 'Poll' -and $early -and -not ($release -and $release.testMode) -and $rb) {
        $org = $svc.ado.organization; $proj = $svc.ado.project; $repo = $svc.ado.repository
        $h = @{ Authorization = "Bearer $(Get-AdoToken)" }
        switch ($phase) {
            'pr-open' {
                $pr = Invoke-RestMethod -Uri "https://dev.azure.com/$org/$proj/_apis/git/repositories/$repo/pullrequests/$([int]$rb['prId'])?api-version=7.1" -Headers $h -ErrorAction Stop
                if ($pr.status -eq 'completed') {
                    if (Set-RevertBits 'pr-open' @{ phase = 'queue-build'; prMergedAt = $(if ($pr.closedDate) { (ConvertTo-UtcDate $pr.closedDate).ToString('o') } else { Get-NowIso }); error = $null }) {
                        $out.Transition = 'pr-open -> queue-build'
                        Write-Audit @{ event = 'revert-bits-pr-merged'; prId = $rb['prId'] }
                    }
                } elseif ($pr.status -eq 'abandoned') {
                    if (Set-RevertBits 'pr-open' @{ phase = 'failed'; error = "Revert bits PR $($rb['prId']) was abandoned."; failedAt = Get-NowIso }) {
                        $out.Transition = 'pr-open -> failed'; $out.NotifyEvent = 'revert-bits-failed'
                        Write-Audit @{ event = 'revert-bits-pr-abandoned'; prId = $rb['prId'] }
                    }
                }
            }
            'queue-build' {
                $branch = [string]$rb['revertBranch']
                $rrb = $ResolveBuildScript
                $dc = & $rrb -Action DeployCommit -DeployBranch $branch -RepoPath $RepoPath -ServiceConfigPath $ServiceConfigPath -AccessToken (Get-AdoToken)
                if (-not $dc.Success) { throw "Revert build lookup on ${branch}: $($dc.Error)" }
                $buildId = $dc.BuildId; $reused = [bool]$buildId
                if (-not $buildId) {
                    $since = ConvertTo-UtcDate $rb['prMergedAt']
                    if ($since -and ((Get-UtcNow) - $since).TotalMinutes -lt $CiGraceMinutes) { $out.Transition = 'waiting for CI build' }
                    else {
                        $qb = & $rrb -Action QueueBuild -Commit $dc.Commit -DeployBranch $branch -RepoPath $RepoPath -ServiceConfigPath $ServiceConfigPath -AccessToken (Get-AdoToken)
                        if (-not $qb.Success) { throw "Queueing the revert build on ${branch}: $($qb.Error)" }
                        $buildId = $qb.BuildId
                    }
                }
                if ($buildId) {
                    $b = Invoke-RestMethod -Uri "https://dev.azure.com/$org/$proj/_apis/build/builds/$([long]$buildId)?api-version=7.1" -Headers $h -ErrorAction Stop
                    $url = "https://dev.azure.com/$org/$proj/_build/results?buildId=$buildId"
                    if (Set-RevertBits 'queue-build' @{ phase = 'building'; buildId = [long]$buildId; buildNumber = [string]$b.buildNumber; buildUrl = $url; revertCommit = $dc.Commit; buildQueuedAt = Get-NowIso; error = $null }) {
                        $out.Transition = 'queue-build -> building'
                        Write-Audit @{ event = 'revert-bits-build'; buildId = $buildId; buildNumber = $b.buildNumber; commit = $dc.Commit; reused = $reused }
                    }
                }
            }
            'building' {
                $b = Invoke-RestMethod -Uri "https://dev.azure.com/$org/$proj/_apis/build/builds/$([long]$rb['buildId'])?api-version=7.1" -Headers $h -ErrorAction Stop
                if ($b.status -eq 'completed') {
                    if ($b.result -in @('succeeded', 'partiallySucceeded')) {
                        if (Set-RevertBits 'building' @{ phase = 'ready'; readyAt = Get-NowIso; buildNumber = [string]$b.buildNumber; error = $null }) {
                            $out.Transition = 'building -> ready'; $out.NotifyEvent = 'revert-bits-ready'
                            Write-Audit @{ event = 'revert-bits-ready'; buildId = $rb['buildId']; buildNumber = $b.buildNumber }
                        }
                    } elseif (Set-RevertBits 'building' @{ phase = 'failed'; error = "Revert build $($b.buildNumber) ended '$($b.result)'."; failedAt = Get-NowIso }) {
                        $out.Transition = 'building -> failed'; $out.NotifyEvent = 'revert-bits-failed'
                        Write-Audit @{ event = 'revert-bits-build-failed'; buildId = $rb['buildId']; result = $b.result }
                    }
                }
            }
        }
    }
    $rb = Get-RevertBits
    $out.Phase = if ($rb) { [string]$rb['phase'] } else { $null }
    $out.RevertBits = $rb
    $out.Success = $true
} catch {
    $out.Error = $_.Exception.Message
    try {
        # report a repeated error only once
        $rb = Get-RevertBits
        if ($rb -and [string]$rb['lastError'] -ne $out.Error) {
            $p = [string]$rb['phase']
            if (Set-RevertBits $p @{ lastError = $out.Error; lastErrorAt = Get-NowIso }) { $out.NotifyEvent = 'revert-bits-failed' }
        }
        $out.Phase = if ($rb) { [string]$rb['phase'] } else { $null }
    } catch { }
    Write-Audit @{ event = 'revert-bits-track-error'; error = $out.Error }
    if ($Action -eq 'Get') { throw }
}
return $out
