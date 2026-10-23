BeforeAll {
    $script:coldResumeScript = "$PSScriptRoot\..\scripts\Invoke-ColdResume.ps1"
}

Describe 'Invoke-ColdResume' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        Push-Location $testRoot
    }

    AfterEach { Pop-Location }

    Context 'No active release found' {
        It 'returns none verdict when no state directories exist' {
            $result = & $script:coldResumeScript
            $result.Action | Should -Be 'none'
            $result.ReleaseId | Should -BeNullOrEmpty
        }
    }

    Context 'Active release in .zed-agent/ (local)' {
        BeforeEach {
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            New-Item -ItemType Directory -Path $relDir -Force | Out-Null

            $state = @{
                releaseId = '2026-04'; status = 'in-progress'
                lastUpdated = (Get-Date -Format 'o')
                steps = @(
                    @{ number = 1; name = 'send-reminder'; status = 'completed' }
                    @{ number = 2; name = 'cut-branch'; status = 'completed' }
                    @{ number = 3; name = 'wait-build'; status = 'in-progress' }
                    @{ number = 4; name = 'collect-commits'; status = 'pending' }
                    @{ number = 5; name = 'deploy-canary'; status = 'pending' }
                )
                watcherDirective = @{ action = 'poll-ado-build'; target = 'https://dev.azure.com/test' }
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $relDir 'state.json') -Encoding UTF8
        }

        It 'discovers the release and returns a verdict' {
            $result = & $script:coldResumeScript
            $result.ReleaseId | Should -Be '2026-04'
            $result.Action | Should -Not -Be 'no-release'
        }

        It 'identifies current step from state' {
            $result = & $script:coldResumeScript
            $result.CurrentStep | Should -BeGreaterOrEqual 3
        }

        It 'does not auto-continue cached BVT completion without creation-time official evidence' {
            $state.steps = @(@{ number = 8; name = 'post-rollback-bvt'; status = 'in-progress' })
            $state.watcherDirective = @{ action = 'poll-bvt-releases'; step = 8 }
            $state.bvtReleases = @{ '8' = @{ status = 'completed'; runs = @{
                'IaaSVM-CloudTest' = @{ releaseId = 17877228; status = 'completed'; outcome = 'succeeded' }
            } } }
            $state | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $relDir 'state.json')
            $result = & $script:coldResumeScript
            $result.Action | Should -Be 'resume-step'
            $result.DirectiveEvaluation.ConditionMet | Should -Not -BeTrue
            $result.DirectiveEvaluation.Details | Should -Match 'evidence not verified'
        }
    }

    Context 'Active release in .zed-release/ (durable)' {
        BeforeEach {
            $relDir = Join-Path $testRoot '.zed-release/releases/2026-05'
            New-Item -ItemType Directory -Path $relDir -Force | Out-Null

            $state = @{
                releaseId = '2026-05'; status = 'in-progress'
                lastUpdated = (Get-Date -Format 'o')
                steps = @(
                    @{ number = 1; name = 'send-reminder'; status = 'completed' }
                    @{ number = 2; name = 'cut-branch'; status = 'in-progress' }
                )
                watcherDirective = $null
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $relDir 'state.json') -Encoding UTF8
        }

        It 'discovers durable release and returns verdict' {
            $result = & $script:coldResumeScript
            $result.ReleaseId | Should -Be '2026-05'
            $result.Action | Should -Not -Be 'no-release'
        }
    }

    Context 'Completed release is skipped' {
        BeforeEach {
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-03'
            New-Item -ItemType Directory -Path $relDir -Force | Out-Null

            $state = @{
                releaseId = '2026-03'; status = 'completed'
                lastUpdated = (Get-Date -Format 'o')
                steps = @(
                    @{ number = 1; name = 'send-reminder'; status = 'completed' }
                )
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $relDir 'state.json') -Encoding UTF8
        }

        It 'returns none when only completed releases exist' {
            $result = & $script:coldResumeScript
            $result.Action | Should -Be 'none'
        }
    }
}
