BeforeAll {
    $script:Resolver = Join-Path $PSScriptRoot '..\scripts\EV2\Resolve-Ev2StageTransition.ps1'
    . (Join-Path $PSScriptRoot '..\scripts\Expand-Template.ps1')

    function New-Stage([string]$Name, [string]$Status = 'Succeeded', [int]$Completed = 1, [int]$Total = 1) {
        [pscustomobject]@{ name = $Name; status = $Status; completedRegions = $Completed; totalRegions = $Total }
    }
}

Describe 'EV2 stage notification resolution' {
    It 'does not wrap Heavy back to Low when API stages arrive alphabetically' {
        $stages = @(
            New-Stage Canary
            New-Stage Heavy
            New-Stage Low
            New-Stage Medium
        )
        $r = & $script:Resolver -BatchStages $stages
        $r.isVerified | Should -BeTrue
        $r.completedStageName | Should -Be 'Heavy'
        $r.nextStageName | Should -Be 'None - rollout stages complete'
        $r.allStagesCompleted | Should -BeTrue
        $r.waitingForPromotion | Should -BeFalse
        ($r.orderedStages.name -join ',') | Should -Be 'Canary,Low,Medium,Heavy'
    }

    It 'selects Day1 after Heavy only when it exists in the same rollout' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Day1 Waiting 0
            New-Stage Heavy
            New-Stage Canary
            New-Stage Low
            New-Stage Medium
        )
        $r.completedStageName | Should -Be 'Heavy'
        $r.nextStageName | Should -Be 'Day1'
        $r.nextStageStatus | Should -Be 'Waiting'
        $r.waitingForPromotion | Should -BeTrue
        $r.allStagesCompleted | Should -BeFalse
    }

    It 'orders Day10 after Day9 rather than after Day1' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Day10 Queued 0
            New-Stage Day9
            New-Stage Day1
        )
        $r.completedStageName | Should -Be 'Day9'
        $r.nextStageName | Should -Be 'Day10'
    }

    It 'includes ManagedValidation when it is present' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Low NotStarted 0
            New-Stage ManagedValidation Running 0
            New-Stage Canary
        )
        $r.completedStageName | Should -Be 'Canary'
        $r.nextStageName | Should -Be 'ManagedValidation'
        $r.waitingForPromotion | Should -BeFalse
    }

    It 'does not request promotion before the first completion' {
        $r = & $script:Resolver -BatchStages @(New-Stage Canary Waiting 0)
        $r.completedStageName | Should -BeNullOrEmpty
        $r.nextStageName | Should -Be 'Canary'
        $r.waitingForPromotion | Should -BeFalse
    }

    It 'does not request promotion while regions are unfinished' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Canary Succeeded 1 2
            New-Stage Low Waiting 0
        )
        $r.waitingForPromotion | Should -BeFalse
    }

    It 'retains a failed next stage without requesting promotion' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Canary
            New-Stage Low Failed 0
        )
        $r.nextStageName | Should -Be 'Low'
        $r.nextStageStatus | Should -Be 'Failed'
        $r.allStagesCompleted | Should -BeFalse
        $r.waitingForPromotion | Should -BeFalse
    }

    It 'skips stages explicitly marked Skipped' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Canary
            New-Stage Low Skipped 0 0
            New-Stage Medium Queued 0
        )
        $r.completedStageName | Should -Be 'Canary'
        $r.nextStageName | Should -Be 'Medium'
    }

    It 'rejects inconsistent completion rather than hiding earlier unfinished stages' {
        $r = & $script:Resolver -BatchStages @(
            New-Stage Low Running 0
            New-Stage Heavy
        ) -WarningVariable warnings -WarningAction SilentlyContinue
        $r.isVerified | Should -BeFalse
        $r.nextStageName | Should -Be 'Unverified - check EV2 portal'
        $r.error | Should -Match 'Low.*not complete'
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'requires authoritative ordering for custom stage names' {
        $stages = @(New-Stage RingB Waiting 0; New-Stage RingA)
        $r = & $script:Resolver -BatchStages $stages -WarningAction SilentlyContinue
        $r.isVerified | Should -BeFalse
        $r.error | Should -Match 'Stage order is unknown'

        $r = & $script:Resolver -BatchStages $stages -StageOrder @('RingA', 'RingB')
        $r.isVerified | Should -BeTrue
        $r.completedStageName | Should -Be 'RingA'
        $r.nextStageName | Should -Be 'RingB'
    }

    It 'does not claim completion with no batch stages' {
        $r = & $script:Resolver -BatchStages @() -WarningAction SilentlyContinue
        $r.isVerified | Should -BeFalse
        $r.allStagesCompleted | Should -BeFalse
        $r.error | Should -Match 'No batch stages'
    }

    It 'rejects duplicate stage names' {
        $r = & $script:Resolver -BatchStages @(New-Stage Canary; New-Stage Canary) -WarningAction SilentlyContinue
        $r.isVerified | Should -BeFalse
        $r.error | Should -Match 'Duplicate batch stage'
    }

    It 'rejects case-insensitive duplicate stage names' {
        $r = & $script:Resolver -BatchStages @(New-Stage Canary; New-Stage canary) -WarningAction SilentlyContinue
        $r.isVerified | Should -BeFalse
        $r.error | Should -Match 'Duplicate batch stage'
    }

    It 'renders the Outlook email with no next stage after Heavy completes' {
        $r = & $script:Resolver -BatchStages @(New-Stage Heavy; New-Stage Low; New-Stage Medium; New-Stage Canary)
        $variables = @{
            releaseId = 'TEST-RELEASE'
            completedStageName = $r.completedStageName
            nextStageName = $r.nextStageName
            timestamp = '2026-10-28T05:24:42Z'
            routeCount = 1
            geographyCount = 1
            stageMapName = 'TestMap'
            stageMapVersion = '1'
            stageMapStatus = 'verified'
            dashboardRows = '<tr><td>Test</td><td>Public</td><td>Heavy</td><td>Succeeded</td><td>testregion</td></tr>'
            summaryLine = 'All stages complete'
            portalLinks = 'Test portal'
        }
        $html = Expand-Template -TemplatePath (Join-Path $PSScriptRoot '..\templates\ev2-stage-progress-email.html') -Variables $variables
        $html | Should -Match '<b>Next stage:</b> None - rollout stages complete<br>'
        $html | Should -Not -Match '<b>Next stage:</b> Low'
        $html | Should -Not -Match '\{\{'
    }
}

Describe 'EV2 rollout status notification integration' {
    BeforeAll {
        $ev2Dir = Join-Path $TestDrive 'EV2'
        New-Item -ItemType Directory -Path $ev2Dir | Out-Null
        $sourceDir = Join-Path $PSScriptRoot '..\scripts\EV2'
        foreach ($file in @('Get-Ev2RolloutStatus.ps1', 'Resolve-Ev2StageTransition.ps1')) {
            Copy-Item (Join-Path $sourceDir $file) (Join-Path $ev2Dir $file)
        }
        # Isolate configuration/authentication; execute the real parser and resolver.
        Set-Content (Join-Path $TestDrive 'Load-ServiceConfig.ps1') @'
param([string]$ServiceConfigPath)
[pscustomobject]@{
    ado = @{ organization = 'test'; project = 'test' }
    pipelines = @{ ev2ServiceTreeIds = @{ Prod = 'test-service-tree' } }
}
'@
        $script:StatusScript = Join-Path $ev2Dir 'Get-Ev2RolloutStatus.ps1'
        function az { }
    }

    BeforeEach {
        Mock az { 'test-token' }
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                Status = 'Succeeded'
                StageInfos = @(
                    [pscustomobject]@{ StageName = 'Heavy'; StageStatus = 'Succeeded'; ChildStages = @() }
                    [pscustomobject]@{ StageName = 'Low'; StageStatus = 'Succeeded'; ChildStages = @() }
                    [pscustomobject]@{ StageName = 'Canary'; StageStatus = 'Succeeded'; ChildStages = @() }
                    [pscustomobject]@{ StageName = 'Medium'; StageStatus = 'Succeeded'; ChildStages = @() }
                    [pscustomobject]@{ StageName = 'Heavy.testregion'; StageStatus = 'Succeeded' }
                )
                ResourceGroups = @()
            }
        }
    }

    It 'exposes verified email values without changing existing region or batch data' {
        $r = & $script:StatusScript -RolloutId 'test-rollout' -ServiceGroup 'test-service'
        $r.stageTransition.isVerified | Should -BeTrue
        $r.stageTransition.completedStageName | Should -Be 'Heavy'
        $r.stageTransition.nextStageName | Should -Be 'None - rollout stages complete'
        $r.stageTransition.waitingForPromotion | Should -BeFalse
        ($r.batchStages.name -join ',') | Should -Be 'Heavy,Low,Canary,Medium'
        $r.completedNodes.Count | Should -Be 1
        $r.completedNodes[0].name | Should -Be 'testregion'
        $r.overallStatus | Should -Be 'Succeeded'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'surfaces unknown ordering without losing rollout diagnostics' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                Status = 'Running'
                StageInfos = @([pscustomobject]@{ StageName = 'CustomRing'; StageStatus = 'Waiting'; ChildStages = @() })
                ResourceGroups = @()
            }
        }
        $r = & $script:StatusScript -RolloutId 'test-rollout' -ServiceGroup 'test-service' -WarningAction SilentlyContinue
        $r.stageTransition.isVerified | Should -BeFalse
        $r.suggestedActions | Should -Contain $r.stageTransition.error
        $r.overallStatus | Should -Be 'Running'
        $r.batchStages[0].name | Should -Be 'CustomRing'
    }
}
