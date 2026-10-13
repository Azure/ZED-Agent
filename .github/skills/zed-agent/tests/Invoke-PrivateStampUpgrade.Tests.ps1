<#
.SYNOPSIS
    Pester tests for Invoke-PrivateStampUpgrade.ps1 (private stamp upgrade side track:
    kicked off at Step 5, joined at Step 13). ADO REST calls are mocked.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-PrivateStampUpgrade.ps1'

    function New-Env {
        param([string]$Step3 = 'completed', [bool]$TestMode = $false, [bool]$Enabled = $true)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $steps = 1..16 | ForEach-Object { [ordered]@{ number = $_; name = "s$_"; status = 'pending' } }
        $steps[0].status = 'completed'; $steps[1].status = 'completed'; $steps[2].status = $Step3
        [ordered]@{ releaseId = '2026-11'; steps = $steps; watcherDirective = $null; lastUpdated = $null } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'state.json') -Encoding UTF8
        [ordered]@{ releaseId = '2026-11'; currentBranch = 'releases/bcm-2611'; previousBranch = 'releases/bcm-2610'; testMode = $TestMode; releaseOwner = @{ alias = 'o'; email = 'o@x.com' } } |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'release.json') -Encoding UTF8
        [ordered]@{
            privateStampUpgrade = [ordered]@{
                enabled = $Enabled
                id = 396863
                sourceBranch = '{currentBranch}'
                portSpan = 2
                templateParameters = [ordered]@{ rolloutType = 'normal'; DepToolsArtifactBranch = 'develop'; debug = 'False' }
                parameterNames = [ordered]@{ instance = 'PrivateInstance'; port = 'WebRolePort'; artifactBranch = 'ArtifactBranch'; serviceOverrides = 'ServiceOverrideSettings' }
                serviceOverrideSettingsTemplate = '@{"BCMAppConfig->WorkflowQueueName"="{queueName}";}'
            }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'pipeline-catalog.json') -Encoding UTF8
        return $dir
    }

    function Invoke-Psu {
        param([string]$Dir, [string]$Action, [hashtable]$Extra = @{})
        $splat = @{
            Action = $Action; ReleaseId = '2026-11'
            StateFile = (Join-Path $Dir 'state.json'); StateLock = (Join-Path $Dir 'state.json.lock')
            AuditFile = (Join-Path $Dir 'audit.jsonl'); ReleaseFile = (Join-Path $Dir 'release.json')
            PipelineCatalogPath = (Join-Path $Dir 'pipeline-catalog.json')
            Organization = 'msazure'; Project = 'One'; AccessToken = 'tok'
        }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $ScriptPath @splat
    }

    $script:GoodInputs = @{ Instance = 'a'; LastPort = 10060; CurrentPort = 10062; LastArtifactBranch = 'releases/bcm-2610'; QueueName = 'TeeQ-Upgrade.1'; By = 'owner' }

    function Get-Track([string]$Dir) { (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json).privateStampUpgrade }
    function Set-Step3([string]$Dir, [string]$Status) {
        $p = Join-Path $Dir 'state.json'
        $s = Get-Content $p -Raw | ConvertFrom-Json
        ($s.steps | Where-Object number -eq 3).status = $Status
        $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
    }
}

Describe 'Invoke-PrivateStampUpgrade' {

    Context 'Init (Step 5 kick-off)' {
        It 'creates the track once and asks the owner for inputs' {
            $d = New-Env
            $r = Invoke-Psu $d 'Init'
            $r.Status | Should -Be 'awaiting-input'
            $r.NotifyEvent | Should -Be 'private-stamp-input-needed'
            $r2 = Invoke-Psu $d 'Init'
            $r2.Status | Should -Be 'awaiting-input'
            $r2.NotifyEvent | Should -BeNullOrEmpty
        }

        It 'skips the track in test mode' {
            $d = New-Env -TestMode $true
            $r = Invoke-Psu $d 'Init'
            $r.Status | Should -Be 'skipped'
            $r.NotifyEvent | Should -BeNullOrEmpty
            (Get-Track $d).skipReason | Should -Be 'test-mode'
        }

        It 'reports disabled when the catalog block is off' {
            $d = New-Env -Enabled $false
            (Invoke-Psu $d 'Init').Status | Should -Be 'disabled'
            Get-Track $d | Should -BeNullOrEmpty
        }
    }

    Context 'SetInputs validation' {
        It 'rejects <case>' -ForEach @(
            @{ case = 'overlapping ports (port + HTTP port)'; patch = @{ CurrentPort = 10061 }; msg = '*overlap*' }
            @{ case = 'a queue name with quotes';               patch = @{ QueueName = 'q";x' };   msg = '*TeeWorkflowQueueName*' }
            @{ case = 'the current release branch as last build'; patch = @{ LastArtifactBranch = 'releases/bcm-2611' }; msg = '*PREVIOUS build*' }
            @{ case = 'an invalid instance';                    patch = @{ Instance = 'A B' }; msg = '*Instance*' }
        ) {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $in = $GoodInputs.Clone(); foreach ($k in $patch.Keys) { $in[$k] = $patch[$k] }
            { Invoke-Psu $d 'SetInputs' $in } | Should -Throw $msg
            (Get-Track $d).status | Should -Be 'awaiting-input'
        }
    }

    Context 'Happy path: last -> current -> BVT sign-off' {
        It 'waits for the build, then deploys both legs sequentially with the right parameters' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 1001 } }

            $d = New-Env -Step3 'in-progress'
            $null = Invoke-Psu $d 'Init'
            $r = Invoke-Psu $d 'SetInputs' $GoodInputs
            $r.Status | Should -Be 'inputs-ready'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }

            Set-Step3 $d 'completed'
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'deploying-last'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST') { return $false }
                $b = $Body | ConvertFrom-Json
                $Method -eq 'POST' -and $Uri -like '*/pipelines/396863/runs*' -and
                $b.resources.repositories.self.refName -eq 'refs/heads/releases/bcm-2611' -and
                $b.templateParameters.PrivateInstance -eq 'A' -and
                $b.templateParameters.WebRolePort -eq '10060' -and
                $b.templateParameters.ArtifactBranch -eq 'releases/bcm-2610' -and
                $b.templateParameters.ServiceOverrideSettings -eq '@{"BCMAppConfig->WorkflowQueueName"="TeeQ-Upgrade.1";}' -and
                $b.templateParameters.rolloutType -eq 'normal' -and
                $b.templateParameters.DepToolsArtifactBranch -eq 'develop'
            }

            # last still running -> nothing changes
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' } -MockWith { [pscustomobject]@{ status = 'inProgress'; result = $null } }
            (Invoke-Psu $d 'Poll').Status | Should -Be 'deploying-last'

            # last succeeded -> current queued on the second port with this release's build
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 1002 } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' } -MockWith { [pscustomobject]@{ status = 'completed'; result = 'succeeded'; finishTime = '2026-11-05T10:00:00Z' } }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'deploying-current'
            $r.NotifyEvent | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST') { return $false }
                $b = $Body | ConvertFrom-Json
                $Method -eq 'POST' -and $b.templateParameters.WebRolePort -eq '10062' -and
                $b.templateParameters.ArtifactBranch -eq 'releases/bcm-2611' -and
                $b.templateParameters.ServiceOverrideSettings -eq '@{"BCMAppConfig->WorkflowQueueName"="TeeQ-Upgrade.1";}'
            }
            $t = Get-Track $d
            $t.runs.last.result | Should -Be 'succeeded'
            $t.runs.current.runId | Should -Be 1002

            # current succeeded -> owner BVT
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'awaiting-bvt'
            $r.NotifyEvent | Should -Be 'private-stamp-bvt-ready'

            # polling again does not re-notify
            (Invoke-Psu $d 'Poll').NotifyEvent | Should -BeNullOrEmpty

            $r = Invoke-Psu $d 'SignOff' @{ By = 'owner' }
            $r.Status | Should -Be 'signed-off'
            (Get-Track $d).signedOffBy | Should -Be 'owner'
        }

        It 'refuses sign-off before the deployments are done' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            { Invoke-Psu $d 'SignOff' @{ By = 'owner' } } | Should -Throw '*awaiting-bvt*'
        }

        It 'starts immediately at Init when inputs were given before Step 5' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 7 } }
            $d = New-Env -Step3 'in-progress'
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Set-Step3 $d 'completed'
            $r = Invoke-Psu $d 'Init'
            $r.Status | Should -Be 'deploying-last'
            $r.NotifyEvent | Should -BeNullOrEmpty
        }
    }

    Context 'Failures, retry, skip' {
        It 'marks a failed leg, notifies, and retry re-queues only that leg' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 11 } }
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs

            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' } -MockWith { [pscustomobject]@{ status = 'completed'; result = 'failed' } }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            $r.NotifyEvent | Should -Be 'private-stamp-failed'
            (Get-Track $d).failedLeg | Should -Be 'last'

            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 12 } }
            $r = Invoke-Psu $d 'Retry' @{ By = 'owner' }
            $r.Status | Should -Be 'deploying-last'
            (Get-Track $d).runs.last.runId | Should -Be 12
        }

        It 'marks the track failed when queueing the run fails' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { throw 'TF400898: boom' }
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $r = Invoke-Psu $d 'SetInputs' $GoodInputs
            $r.Status | Should -Be 'failed'
            $r.NotifyEvent | Should -Be 'private-stamp-failed'
            (Get-Track $d).error | Should -Match 'TF400898'
        }

        It 'fails a stale trigger claim instead of double-queueing' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $p = Join-Path $d 'state.json'
            $s = Get-Content $p -Raw | ConvertFrom-Json
            $s.privateStampUpgrade.status = 'triggering-last'
            $s.privateStampUpgrade | Add-Member -NotePropertyName claimedAt -NotePropertyValue ((Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')) -Force
            $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
            Mock Invoke-RestMethod { throw 'should not be called' }
            $r = Invoke-Psu $d 'Poll'
            $r.Status | Should -Be 'failed'
            $r.NotifyEvent | Should -Be 'private-stamp-failed'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'Poll never throws on API errors' {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 5 } }
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $null = Invoke-Psu $d 'SetInputs' $GoodInputs
            Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' } -MockWith { throw 'network down' }
            $r = Invoke-Psu $d 'Poll'
            $r.Success | Should -BeFalse
            $r.Error | Should -Match 'network down'
            $r.Status | Should -Be 'deploying-last'
        }

        It 'skip releases the track from any open state' {
            $d = New-Env
            $null = Invoke-Psu $d 'Init'
            $r = Invoke-Psu $d 'Skip' @{ By = 'owner'; Reason = 'stamp unavailable' }
            $r.Status | Should -Be 'skipped'
            (Get-Track $d).previousStatus | Should -Be 'awaiting-input'
        }
    }
}

Describe 'privateStampUpgrade wiring' {
    BeforeAll {
        $script:ResolverPath = Join-Path $PSScriptRoot '..\scripts\Resolve-NotificationRecipients.ps1'
    }

    It 'routes <key> to 5-deploy-canary.<outcome>' -ForEach @(
        @{ key = 'private-stamp-input-needed'; outcome = 'halt' }
        @{ key = 'private-stamp-bvt-ready';    outcome = 'halt' }
        @{ key = 'private-stamp-failed';       outcome = 'failure' }
    ) {
        $rule = [pscustomobject]@{ emailGroups = @('permanent') }
        $step = [pscustomobject]@{}
        $step | Add-Member -NotePropertyName $outcome -NotePropertyValue $rule
        $cfg = [pscustomobject]@{
            notifications = [pscustomobject]@{
                groups  = [pscustomobject]@{ permanent = @('dl@example.com') }
                routing = [pscustomobject]@{ '5-deploy-canary' = $step }
            }
        }
        $rel = [pscustomobject]@{ releaseOwner = [pscustomobject]@{ alias = 'o'; email = 'owner@example.com' } }
        $r = & $ResolverPath -EventKey $key -Config $cfg -Release $rel
        $r.EmailTo | Should -Contain 'dl@example.com'
        $r.EmailTo | Should -Contain 'owner@example.com'
    }

    It 'watcher and cold resume poll the side track every tick' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match "Invoke-PrivateStampUpgrade\.ps1"
        $w | Should -Match "Action\s*=\s*'Poll'"
        $w | Should -Match 'private stamp upgrade \$\(\$psu\.NotifyEvent\)'
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match "Invoke-PrivateStampUpgrade\.ps1"
        $c | Should -Match 'PrivateStampSideChannel'
    }
}
