<#
.SYNOPSIS
    Pester tests for EV2\Get-Ev2DeploymentProgress.ps1 — "is the canary deployment done?" from the
    EV2 rollout (Canary-ManagedValidation started) instead of waiting ~24 h for the pipeline run.
    Shapes copied from BCM canary run 186291713 / rollout 481dbbb6-f88e-4b5e-8027-2e5630017555.
#>

BeforeAll {
    $script:S = Join-Path $PSScriptRoot '..\scripts\EV2\Get-Ev2DeploymentProgress.ps1'
    $script:Link = 'https://ra.ev2portal.azure.net/#/rollouts/Prod/fb10185a-465d-42cd-b339-7d0d9331c340/Microsoft.Azure.Backup.Cntl.Bcm.ACTIVE/481dbbb6-f88e-4b5e-8027-2e5630017555'
    $global:AwLink = $script:Link

    function Invoke-P([hashtable]$Extra = @{}) {
        $splat = @{ RunId = 186291713; Organization = 'msazure'; Project = 'One'; AdoToken = 'ado'; Ev2Token = 'ev2' }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $script:S @splat
    }

    # $Regions: @{ centraluseuap = 'Succeeded'; ... }; $V = validation action status ($null = no action yet)
    function New-Rollout([string]$Status = 'Running', [hashtable]$Regions = @{ centraluseuap = 'Succeeded'; eastus2euap = 'Succeeded' }, [string]$V = 'Running', [string]$VStart = '2026-10-17T12:04:23.935Z', [string]$VEnd = '0001-01-01T00:00:00') {
        $stages = @([pscustomobject]@{ StageName = 'Canary'; StageStatus = $Status; EndTime = '0001-01-01T00:00:00' }
                    [pscustomobject]@{ StageName = 'Canary-__STAGE_PRECHECK__'; StageStatus = 'Succeeded' })
        foreach ($r in $Regions.Keys) { $stages += [pscustomobject]@{ StageName = "Canary.$r"; StageStatus = $Regions[$r]; EndTime = '2026-10-17T12:04:08.1385641Z' } }
        $acts = @([pscustomobject]@{ Name = 'Deploy'; StepName = 'Canary.eastus2euap'; Status = 'Succeeded'; ActionOperationInfo = [pscustomobject]@{ StartTime = '2026-10-17T12:03:30Z'; EndTime = '2026-10-17T12:04:08Z' } })
        if ($V) { $acts += [pscustomobject]@{ Name = 'managedvalidation/canary'; StepName = 'Canary-ManagedValidation'; Status = $V; ActionOperationInfo = [pscustomobject]@{ StartTime = $VStart; EndTime = $VEnd } } }
        [pscustomobject]@{
            RolloutId = '481dbbb6-f88e-4b5e-8027-2e5630017555'; Status = $Status; StageInfos = $stages
            ResourceGroups = @([pscustomobject]@{ Name = 'Ev2-Staging-RGD-eastus2euap-1'; Resources = @([pscustomobject]@{ Name = 'Ev2-Staging-Resource-eastus2euap-1'; Actions = $acts }) })
        }
    }
    function Mock-Run([string]$Log = "2026-10-17T12:02:35.4972894Z ##[warning]Ev2 portal link - $($script:Link)") {
        $global:AwLog = $Log
        $global:AwRecords = @(
            [pscustomobject]@{ id = 'a'; type = 'Task'; name = 'Validate Source Build (OneBranch PT)'; startTime = '2026-10-17T12:01:00Z'; log = [pscustomobject]@{ id = 113 } }
            [pscustomobject]@{ id = 'b'; type = 'Task'; name = 'Ev2 Managed SDP Region Agnostic'; startTime = '2026-10-17T12:01:30Z'; log = [pscustomobject]@{ id = 114 } }
        )
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/186291713/timeline' } -MockWith { [pscustomobject]@{ records = $global:AwRecords } }
        Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/logs/114\?' } -MockWith { [pscustomobject]@{ Content = $global:AwLog } }
        Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/logs/113\?' } -MockWith { throw 'must only read the EV2 task log' }
        Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/logs/214\?' } -MockWith { [pscustomobject]@{ Content = "Ev2 portal link - $($global:AwLink)" } }
    }
}

AfterAll { Remove-Variable -Name AwLog, AwRollout, AwRecords, AwLink -Scope Global -ErrorAction SilentlyContinue }

Describe 'Get-Ev2DeploymentProgress' {
    BeforeEach {
        Mock-Run
        $global:AwRollout = New-Rollout
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '^https://azureservicedeploy\.msft\.net/api/rollouts/481dbbb6' } -MockWith { $global:AwRollout }
    }

    It 'is deployed once every canary region succeeded and Canary-ManagedValidation is running' {
        $p = Invoke-P
        $p.Success | Should -BeTrue
        $p.Phase | Should -Be 'deployed'
        $p.Deployed | Should -BeTrue
        $p.DeployedAt | Should -Match '^2026-10-17T12:04:23'
        $p.ValidationStatus | Should -Be 'Running'
        $p.ValidationEndedAt | Should -BeNullOrEmpty
        $p.RolloutId | Should -Be '481dbbb6-f88e-4b5e-8027-2e5630017555'
        $p.ServiceGroup | Should -Be 'Microsoft.Azure.Backup.Cntl.Bcm.ACTIVE'
        $p.PortalUrl | Should -Be $script:Link
        @($p.Regions).Count | Should -Be 2
        $p.Reason | Should -Match 'all 2 region\(s\) deployed; Canary-ManagedValidation Running'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match 'servicegroupname=Microsoft\.Azure\.Backup\.Cntl\.Bcm\.ACTIVE&api-version=2024-02-01&embed-detail=true' -and $Headers.Authorization -eq 'Bearer ev2' }
    }

    It 'is deployed when the rollout already succeeded' {
        $global:AwRollout = New-Rollout -Status 'Succeeded' -V 'Succeeded' -VEnd '2026-10-18T12:06:24.292Z'
        $p = Invoke-P
        $p.Phase | Should -Be 'deployed'
        $p.ValidationEndedAt | Should -Match '^2026-10-18T12:06:24'
        $p.Reason | Should -Be 'rollout succeeded'
    }

    It 'is still deploying while a region is running or the validation has not started' {
        $global:AwRollout = New-Rollout -Regions @{ centraluseuap = 'Succeeded'; eastus2euap = 'Running' } -V $null
        (Invoke-P).Phase | Should -Be 'deploying'
        (Invoke-P).Reason | Should -Match 'eastus2euap=Running'

        $global:AwRollout = New-Rollout -V 'NotStarted' -VStart '0001-01-01T00:00:00'
        $p = Invoke-P
        $p.Phase | Should -Be 'deploying'
        $p.Reason | Should -Match 'Canary-ManagedValidation not started yet'
    }

    It 'reports failed for a failed region, validation or rollout' {
        $global:AwRollout = New-Rollout -Status 'Failed' -Regions @{ centraluseuap = 'Failed'; eastus2euap = 'Succeeded' } -V $null
        $p = Invoke-P
        $p.Phase | Should -Be 'failed'
        $p.Deployed | Should -BeFalse
        $p.Reason | Should -Match 'centraluseuap=Failed'

        $global:AwRollout = New-Rollout -Status 'Failed' -V 'Failed'
        (Invoke-P).Reason | Should -Match 'Canary-ManagedValidation Failed'
    }

    It 'returns no-rollout while the run has no EV2 portal link (e.g. waiting on the Approval Service)' {
        Mock-Run -Log 'Approval pending'
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'azureservicedeploy' } -MockWith { throw 'must not call EV2' }
        $p = Invoke-P
        $p.Success | Should -BeTrue
        $p.Phase | Should -Be 'no-rollout'
    }

    It 'uses the newest link when the stage was retried' {
        # older attempt (log 114) printed another rollout; the retry (log 214, later) printed 481dbbb6
        $global:AwLog = 'Ev2 portal link - https://ra.ev2portal.azure.net/#/rollouts/Prod/fb10185a-465d-42cd-b339-7d0d9331c340/Microsoft.Azure.Backup.Cntl.Bcm.ACTIVE/00000000-0000-0000-0000-000000000001'
        $global:AwRecords = @(
            [pscustomobject]@{ id = 'b2'; type = 'Task'; name = 'Ev2 Managed SDP Region Agnostic'; startTime = '2026-10-17T14:00:00Z'; log = [pscustomobject]@{ id = 214 } }
            [pscustomobject]@{ id = 'b1'; type = 'Task'; name = 'Ev2 Managed SDP Region Agnostic'; startTime = '2026-10-17T12:01:30Z'; log = [pscustomobject]@{ id = 114 } }
        )
        (Invoke-P).RolloutId | Should -Be '481dbbb6-f88e-4b5e-8027-2e5630017555'
    }

    It 'does not call EV2 for a gov-cloud rollout' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'azureservicedeploy' } -MockWith { throw 'must not call EV2' }
        $p = Invoke-P @{ PortalUrl = 'https://ra.ev2portal.azure.net/#/rollouts/Fairfax/abc/Microsoft.Azure.Backup.Cntl.Bcm.ACTIVE/481dbbb6-f88e-4b5e-8027-2e5630017555' }
        $p.Phase | Should -Be 'unsupported-cloud'
        $p.Cloud | Should -Be 'Fairfax'
    }

    It 'never throws — API errors come back as Phase error' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'azureservicedeploy' } -MockWith { throw 'HTTP 403' }
        $p = Invoke-P
        $p.Success | Should -BeFalse
        $p.Phase | Should -Be 'error'
        $p.Error | Should -Match '403'
    }
}

Describe 'EV2 deployment-done wiring' {
    It 'watcher marks deploymentDoneWhen runs deployed and counts them as done; cold resume too' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match 'function Get-DeploymentDoneRules'
        $w | Should -Match 'deploymentDoneWhen'
        $w | Should -Match "Update-TargetFromEv2 -Target \`$t"
        $w | Should -Match "status -in @\('completed','failed','deployed'\)\) \{ continue \}"
        $w | Should -Match "status -notin @\('completed','failed','deployed'\)\) \{ \`$allDone = \`$false \}"
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match "notin @\('completed', 'failed', 'deployed'\)"
    }
}
