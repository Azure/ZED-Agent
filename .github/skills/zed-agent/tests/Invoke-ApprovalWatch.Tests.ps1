<#
.SYNOPSIS
    Pester tests for Invoke-ApprovalWatch.ps1 (pipeline runs waiting on the OneBranch Approval
    Service / ADO approvals → email + Teams messages with the approval link). ADO is mocked with the
    timeline shape of BCM canary run 186266333 (Release-2610-12), which was also verified live.
#>

BeforeAll {
    $script:S = Join-Path $PSScriptRoot '..\scripts\Invoke-ApprovalWatch.ps1'
    $script:Url = 'https://approval.azengsys.com/approvalRequest?id=BD73B6DD5C88431EAA170B044C9B28E7'

    function New-Env([hashtable]$Triggered = @{ '5' = @(186266333) }, [bool]$TestMode = $false) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $dir | Out-Null
        [ordered]@{ releaseId = '2026-10'; currentStep = 5; triggeredPipelines = $Triggered; steps = @() } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'state.json')
        @{ releaseId = '2026-10'; testMode = $TestMode; releaseOwner = @{ alias = 'owner'; email = 'owner@x.com' } } | ConvertTo-Json | Set-Content (Join-Path $dir 'release.json')
        @{ ado = @{ organization = 'msazure'; project = 'One' }; service = @{ displayName = 'BCM' }; operational = @{ approvalReminderHours = 4; approvalExpiryWarnHours = 12 } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'svc.json')
        return $dir
    }
    function Invoke-AW([string]$Dir, [hashtable]$Extra = @{}) {
        $splat = @{ Action = 'Sync'; ReleaseId = '2026-10'; StateFile = (Join-Path $Dir 'state.json'); StateLock = (Join-Path $Dir 'l'); AuditFile = (Join-Path $Dir 'a.jsonl'); ReleaseFile = (Join-Path $Dir 'release.json'); ServiceConfigPath = (Join-Path $Dir 'svc.json'); AccessToken = 'tok' }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $script:S @splat
    }
    function Get-Req([string]$Dir) { (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json).approvalRequests.PSObject.Properties.Value }

    # Timeline/log shapes copied from run 186266333.
    function Set-Run([string]$TaskState = 'pending', [string]$TaskResult = $null, [string]$BuildStatus = 'inProgress', [switch]$NoLink, [switch]$AdoApproval) {
        $global:AwRun = @{ state = $TaskState; result = $TaskResult; status = $BuildStatus; noLink = [bool]$NoLink; ado = [bool]$AdoApproval }
    }
    function Mock-Ado {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/186266333\?' } -MockWith {
            [pscustomobject]@{ id = 186266333; buildNumber = 'Release-2610-12'; status = $global:AwRun.status; definition = [pscustomobject]@{ id = 391437; name = 'Mgmt-RecoverySvcs-IaaSCoord-BCM-Canary-Service-Deployment' } }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/186266333/timeline' } -MockWith {
            $recs = @(
                [pscustomobject]@{ id = 'stage'; type = 'Stage'; name = 'PROD: Managed SDP Deployment'; state = 'inProgress'; result = $null; parentId = $null; startTime = '2026-10-17T05:08:23Z' }
                [pscustomobject]@{ id = 'phase'; type = 'Phase'; name = 'ApprovalService'; state = 'pending'; result = $null; parentId = 'stage' }
                [pscustomobject]@{ id = 'job'; type = 'Job'; name = 'ApprovalService'; state = $global:AwRun.state; result = $global:AwRun.result; parentId = 'phase' }
                [pscustomobject]@{ id = 'task'; type = 'Task'; name = 'Approval service'; state = $global:AwRun.state; result = $global:AwRun.result; parentId = 'job'; log = [pscustomobject]@{ id = 95 } }
                [pscustomobject]@{ id = 'wait'; type = 'task'; name = 'Waiting for Approval'; state = 'completed'; result = 'succeeded'; parentId = 'job'; startTime = '2026-10-17T05:08:39Z'; log = [pscustomobject]@{ id = 96 } }
                [pscustomobject]@{ id = 'prc'; type = 'Checkpoint.ProductionReadinessCheck'; name = 'Checkpoint.ProductionReadinessCheck'; state = 'inProgress'; result = $null; parentId = 'stage' }
            )
            if ($global:AwRun.ado) { $recs += [pscustomobject]@{ id = 'appr'; type = 'Checkpoint.Approval'; name = 'Checkpoint.Approval'; state = 'inProgress'; result = $null; parentId = 'stage'; startTime = '2026-10-17T06:00:00Z' } }
            [pscustomobject]@{ records = $recs }
        }
        Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/logs/96\?' } -MockWith {
            if ($global:AwRun.noLink) { return [pscustomobject]@{ Content = 'Creating approval document...' } }
            [pscustomobject]@{ Content = "Please approve release from https://approval.azengsys.com/approvalRequest?id=BD73B6DD5C88431EAA170B044C9B28E7`nApproval Task will expire on 2026-10-22 04:18:32Z. Approval Task expiration doesn't cause a release Approval Request rejection." }
        }
        Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/logs/95\?' } -MockWith { [pscustomobject]@{ Content = 'POST https://onebranchapprovalserviceprod.trafficmanager.net/azureDevOpsTaskApi/CreateReleaseV3' } }
    }
}

AfterAll { Remove-Variable -Name AwRun -Scope Global -ErrorAction SilentlyContinue }

Describe 'Invoke-ApprovalWatch' {
    BeforeEach { Set-Run; Mock-Ado }

    It 'finds the Approval Service wait, its link, stage, start and expiry, and renders the message' {
        $d = New-Env
        $r = Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-17T06:00:00Z' }
        $r.Success | Should -BeTrue
        @($r.NotifyEvents).Count | Should -Be 1
        $r.NotifyEvents[0].event | Should -Be 'approval-needed'
        $r.NotifyEvents[0].eventKey | Should -Be 'approval-needed'
        $q = Get-Req $d
        $q.kind | Should -Be 'approval-service'
        $q.url | Should -Be $script:Url
        @($q.stages) | Should -Be @('PROD: Managed SDP Deployment')
        $q.step | Should -Be '5'
        $q.lastMessage.subject | Should -BeLike '🔐 Approval needed — Mgmt-RecoverySvcs-IaaSCoord-BCM-Canary-Service-Deployment | BCM 2026-10'
        $q.lastMessage.html | Should -Match ([regex]::Escape($script:Url))
        $q.lastMessage.html | Should -Match '2026-10-17 05:08 UTC \(17 Oct 10:38 IST\)'
        $q.lastMessage.html | Should -Match '2026-10-22 04:18 UTC'
        $q.lastMessage.html | Should -Match 'Step 5 · Canary deployment'
        $q.lastMessage.html | Should -Not -Match '\{\{'
    }

    It 'does not notify twice, reminds after the reminder interval, and warns once before expiry' {
        $d = New-Env
        $null = Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-17T06:00:00Z' }
        @((Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-17T07:00:00Z' }).NotifyEvents).Count | Should -Be 0
        $r = Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-17T10:30:00Z' }
        $r.NotifyEvents[0].event | Should -Be 'approval-reminder'
        (Get-Req $d).lastMessage.subject | Should -BeLike '⏰ Reminder #1:*'
        $r = Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-21T17:00:00Z' }
        $r.NotifyEvents[0].event | Should -Be 'approval-expiring'
        @((Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-21T18:00:00Z' }).NotifyEvents).Count | Should -Be 0
    }

    It 'waits for the link before notifying' {
        Set-Run -NoLink
        $d = New-Env
        @((Invoke-AW $d).NotifyEvents).Count | Should -Be 0
        Get-Req $d | Should -BeNullOrEmpty
    }

    It 'records approval silently and reports an approval task that ended without approval' {
        $d = New-Env
        $null = Invoke-AW $d -Extra @{ Now = [datetime]'2026-10-17T06:00:00Z' }
        Set-Run -TaskState 'completed' -TaskResult 'succeeded'
        @((Invoke-AW $d).NotifyEvents).Count | Should -Be 0
        (Get-Req $d).status | Should -Be 'approved'

        $d2 = New-Env
        Set-Run
        $null = Invoke-AW $d2 -Extra @{ Now = [datetime]'2026-10-17T06:00:00Z' }
        Set-Run -TaskState 'completed' -TaskResult 'failed'
        $r = Invoke-AW $d2
        $r.NotifyEvents[0].event | Should -Be 'approval-failed'
        $r.NotifyEvents[0].eventKey | Should -Be 'approval-failed'
        (Get-Req $d2).status | Should -Be 'ended'
        (Get-Req $d2).lastMessage.subject | Should -BeLike '❌ Approval task ended (failed)*'
    }

    It 'ignores non-approval checks and reports ADO approval checks with the run link' {
        Set-Run -TaskState 'completed' -TaskResult 'succeeded' -AdoApproval
        $d = New-Env
        $r = Invoke-AW $d
        @($r.NotifyEvents).Count | Should -Be 1
        $q = Get-Req $d
        $q.kind | Should -Be 'ado-approval'
        $q.lastMessage.html | Should -Match 'buildId=186266333'
        $q.lastMessage.html | Should -Match 'Approve in Azure DevOps'
    }

    It 'stops reading a run once it has completed with nothing pending' {
        Set-Run -TaskState 'completed' -TaskResult 'succeeded' -BuildStatus 'completed'
        $d = New-Env
        $null = Invoke-AW $d
        (Get-Content (Join-Path $d 'state.json') -Raw | ConvertFrom-Json).approvalWatch.doneRuns | Should -Contain 186266333
        $null = Invoke-AW $d
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match '/build/builds/186266333\?' }
    }

    It 'watches private stamp runs and step keys like step5 / object values' {
        $d = New-Env -Triggered @{ 'step15' = @(@{ runId = 186266333 }) }
        $null = Invoke-AW $d
        (Get-Req $d).step | Should -Be '15'
        (Get-Req $d).lastMessage.html | Should -Match 'Step 15 · Production rollout'
    }

    It 'does nothing in test mode' {
        Mock Invoke-RestMethod -ParameterFilter { $true } -MockWith { throw 'no calls in test mode' }
        $d = New-Env -TestMode $true
        $r = Invoke-AW $d
        $r.Success | Should -BeTrue
        @($r.NotifyEvents).Count | Should -Be 0
    }

    It 'never throws on API errors' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/_apis/' } -MockWith { throw 'network down' }
        $d = New-Env
        $r = Invoke-AW $d
        $r.Success | Should -BeTrue
        @($r.NotifyEvents).Count | Should -Be 0
        Get-Content (Join-Path $d 'a.jsonl') -Raw | Should -Match 'approval-watch-run-error'
    }
}

Describe 'approval routing and wiring' {
    It 'routes <key> to approval-requests.<outcome>' -ForEach @(
        @{ key = 'approval-needed'; outcome = 'halt' }, @{ key = 'approval-reminder'; outcome = 'halt' }
        @{ key = 'approval-expiring'; outcome = 'halt' }, @{ key = 'approval-failed'; outcome = 'failure' }
    ) {
        $rule = [pscustomobject]@{ emailGroups = @('permanent'); teamsGroups = @('teamsExtended') }
        $row = [pscustomobject]@{}; $row | Add-Member -NotePropertyName $outcome -NotePropertyValue $rule
        $cfg = [pscustomobject]@{ notifications = [pscustomobject]@{ groups = [pscustomobject]@{ permanent = @('dl@x.com'); teamsExtended = @('Team Chat') }; routing = [pscustomobject]@{ 'approval-requests' = $row } } }
        $rel = [pscustomobject]@{ releaseOwner = [pscustomobject]@{ alias = 'o'; email = 'o@x.com' } }
        $sec = [pscustomobject]@{ teamsChats = [pscustomobject]@{ 'Team Chat' = '19:abc@thread.v2' } }
        $r = & (Join-Path $PSScriptRoot '..\scripts\Resolve-NotificationRecipients.ps1') -EventKey $key -Config $cfg -Release $rel -Secrets $sec
        $r.EmailTo | Should -Contain 'dl@x.com'
        $r.EmailTo | Should -Contain 'o@x.com'
        $r.TeamsConversationIds | Should -Contain '19:abc@thread.v2'
    }

    It 'watcher runs the approval side-channel on every tick and during the sleep; cold resume too' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match 'function Invoke-ApprovalSideChannel'
        ([regex]::Matches($w, '(?m)^\s+Invoke-ApprovalSideChannel\s*$')).Count | Should -BeGreaterOrEqual 2
        $w | Should -Match 'approval \$\(\$ev\.event\) \$\(\$ev\.id\) for release'
        $w | Should -Not -Match 'postedApprovalUrls'
        Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw | Should -Match 'ApprovalSideChannel'
    }

    It 'the loader accepts an approval-requests routing row' {
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Load-ServiceConfig.ps1') -Raw
        $c | Should -Match "'approval-requests'"
    }
}
