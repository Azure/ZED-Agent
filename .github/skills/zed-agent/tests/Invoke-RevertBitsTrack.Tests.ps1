<#
.SYNOPSIS
    Pester tests for Invoke-RevertBitsTrack.ps1 — revert bits prepared during the canary BVT
    (revertBits.prepareDuringCanaryBvt): PR merged → reuse/queue the revert build → 'ready', so
    Step 7 can roll back right after approve-bvt. ADO and Resolve-ReleaseBuild are stubbed.
#>

BeforeAll {
    $script:S = Join-Path $PSScriptRoot '..\scripts\Invoke-RevertBitsTrack.ps1'

    function New-Env([hashtable]$Rb, [bool]$Early = $true, [bool]$TestMode = $false) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $dir | Out-Null
        [ordered]@{ releaseId = '2026-11'; pipelineTriggerTimestamps = @{ step5 = '2026-11-16T05:08:39Z' }; steps = @(); revertBits = $Rb } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'state.json')
        @{ releaseId = '2026-11'; testMode = $TestMode } | ConvertTo-Json | Set-Content (Join-Path $dir 'release.json')
        @{ ado = @{ organization = 'msazure'; project = 'One'; repository = 'Mgmt-RecoverySvcs-IaaSCoord' }
           revertBits = @{ enabled = $true; prepareDuringCanaryBvt = $Early; prPollIntervalSeconds = 900 } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'svc.json')
        # Resolve-ReleaseBuild stub: DeployCommit → $global:RbDc; QueueBuild → records the call
        @'
param([string]$Action, [string]$DeployBranch, [string]$Commit, [string]$RepoPath, [string]$ServiceConfigPath, [string]$AccessToken)
if ($Action -eq 'DeployCommit') { return $global:RbDc }
$global:RbQueued += ,@{ Commit = $Commit; Branch = $DeployBranch }
return [pscustomobject]@{ Success = $true; BuildId = 99002; Commit = $Commit }
'@ | Set-Content (Join-Path $dir 'rrb.ps1')
        return $dir
    }
    function Invoke-T([string]$Dir, [hashtable]$Extra = @{}) {
        $splat = @{ Action = 'Poll'; ReleaseId = '2026-11'; StateFile = (Join-Path $Dir 'state.json'); StateLock = (Join-Path $Dir 'l'); AuditFile = (Join-Path $Dir 'a.jsonl'); ReleaseFile = (Join-Path $Dir 'release.json'); ServiceConfigPath = (Join-Path $Dir 'svc.json'); ResolveBuildScript = (Join-Path $Dir 'rrb.ps1'); AccessToken = 'tok' }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $script:S @splat
    }
    function Get-Rb([string]$Dir) { (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json).revertBits }
    $script:Sha = 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00'
}

AfterAll { Remove-Variable -Name RbDc, RbQueued -Scope Global -ErrorAction SilentlyContinue }

Describe 'Invoke-RevertBitsTrack' {
    BeforeEach {
        $global:RbQueued = @()
        $global:RbDc = [pscustomobject]@{ Success = $true; Commit = $script:Sha; BuildId = $null }
    }

    It 'moves a merged PR to queue-build, reuses the CI build, and reports ready when it succeeds' {
        $d = New-Env @{ phase = 'pr-open'; prId = 1234; revertBranch = 'releases/bcm2611revert' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/pullrequests/1234\?' } -MockWith { [pscustomobject]@{ status = 'completed'; closedDate = '2026-11-16T09:00:00Z' } }
        $r = Invoke-T $d
        $r.Transition | Should -Be 'pr-open -> queue-build'
        $r.NotifyEvent | Should -BeNullOrEmpty
        (Get-Rb $d).phase | Should -Be 'queue-build'

        $global:RbDc = [pscustomobject]@{ Success = $true; Commit = $script:Sha; BuildId = 99001 }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/99001\?' } -MockWith { [pscustomobject]@{ id = 99001; buildNumber = '3.0.900.0'; status = 'inProgress' } }
        $r = Invoke-T $d -Extra @{ Now = [datetime]'2026-11-16T09:05:00Z' }
        $r.Transition | Should -Be 'queue-build -> building'
        @($global:RbQueued).Count | Should -Be 0     # CI build reused, nothing queued
        $rb = Get-Rb $d
        $rb.buildId | Should -Be 99001
        $rb.revertCommit | Should -Be $script:Sha
        $rb.buildUrl | Should -Match 'buildId=99001'

        $r = Invoke-T $d   # still running
        $r.Transition | Should -BeNullOrEmpty
        (Get-Rb $d).phase | Should -Be 'building'

        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/99001\?' } -MockWith { [pscustomobject]@{ id = 99001; buildNumber = '3.0.900.0'; status = 'completed'; result = 'succeeded' } }
        $r = Invoke-T $d
        $r.Transition | Should -Be 'building -> ready'
        $r.NotifyEvent | Should -Be 'revert-bits-ready'
        (Get-Rb $d).phase | Should -Be 'ready'
        (Get-Rb $d).readyAt | Should -Not -BeNullOrEmpty
        (Invoke-T $d).NotifyEvent | Should -BeNullOrEmpty   # ready is terminal for the track
    }

    It 'waits for CI after the merge, then queues the build pinned to the merge commit' {
        $d = New-Env @{ phase = 'queue-build'; prMergedAt = '2026-11-16T09:00:00Z'; revertBranch = 'releases/bcm2611revert' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/99002\?' } -MockWith { [pscustomobject]@{ id = 99002; buildNumber = '3.0.901.0'; status = 'notStarted' } }
        $r = Invoke-T $d -Extra @{ Now = [datetime]'2026-11-16T09:04:00Z' }
        $r.Transition | Should -Be 'waiting for CI build'
        @($global:RbQueued).Count | Should -Be 0
        $r = Invoke-T $d -Extra @{ Now = [datetime]'2026-11-16T09:12:00Z' }
        $r.Transition | Should -Be 'queue-build -> building'
        @($global:RbQueued).Count | Should -Be 1
        $global:RbQueued[0].Commit | Should -Be $script:Sha
        $global:RbQueued[0].Branch | Should -Be 'releases/bcm2611revert'
        (Get-Rb $d).buildId | Should -Be 99002
    }

    It 'reports a failed build and an abandoned PR' {
        $d = New-Env @{ phase = 'building'; buildId = 99001; revertBranch = 'releases/bcm2611revert' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/99001\?' } -MockWith { [pscustomobject]@{ id = 99001; buildNumber = '3.0.900.0'; status = 'completed'; result = 'failed' } }
        $r = Invoke-T $d
        $r.NotifyEvent | Should -Be 'revert-bits-failed'
        (Get-Rb $d).phase | Should -Be 'failed'
        (Get-Rb $d).error | Should -Match "ended 'failed'"

        $d2 = New-Env @{ phase = 'pr-open'; prId = 1234; revertBranch = 'x' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/pullrequests/1234\?' } -MockWith { [pscustomobject]@{ status = 'abandoned' } }
        (Invoke-T $d2).NotifyEvent | Should -Be 'revert-bits-failed'
        (Get-Rb $d2).error | Should -Match 'abandoned'
    }

    It 'reports a lookup error once and never throws' {
        $d = New-Env @{ phase = 'pr-open'; prId = 1234; revertBranch = 'x' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/pullrequests/' } -MockWith { throw 'HTTP 503' }
        $r = Invoke-T $d
        $r.Success | Should -BeFalse
        $r.Error | Should -Match '503'
        $r.NotifyEvent | Should -Be 'revert-bits-failed'
        (Get-Rb $d).phase | Should -Be 'pr-open'
        (Invoke-T $d).NotifyEvent | Should -BeNullOrEmpty
    }

    It 'does nothing without prepareDuringCanaryBvt, in test mode, or once ready/signed-off' {
        Mock Invoke-RestMethod { throw 'no API calls' }
        (Invoke-T (New-Env @{ phase = 'pr-open'; prId = 1 } -Early $false)).Transition | Should -BeNullOrEmpty
        (Invoke-T (New-Env @{ phase = 'pr-open'; prId = 1 } -TestMode $true)).Transition | Should -BeNullOrEmpty
        $r = Invoke-T (New-Env @{ phase = 'ready'; buildId = 1 })
        $r.Success | Should -BeTrue
        $r.Phase | Should -Be 'ready'
    }
}

Describe 'Revert bits side-channel wiring' {
    It 'watcher and cold resume run the track; notifications are routed' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match 'function Invoke-RevertBitsSideChannel'
        ([regex]::Matches($w, '(?m)^\s+Invoke-RevertBitsSideChannel\s*$')).Count | Should -Be 2
        $w | Should -Match "phase -notin @\('pr-open', 'queue-build', 'building'\)"
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match 'Invoke-RevertBitsTrack\.ps1'
        $c | Should -Match 'RevertBitsSideChannel'
        $n = Get-Content (Join-Path $PSScriptRoot '..\scripts\Resolve-NotificationRecipients.ps1') -Raw
        $n | Should -Match "'revert-bits-ready'\s+= @\{ Step = 7; Outcome = 'halt'"
        $n | Should -Match "'revert-bits-failed'\s+= @\{ Step = 7; Outcome = 'failure'"
    }
}
