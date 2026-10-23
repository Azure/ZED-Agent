BeforeAll {
    $script:driftHaltScript = "$PSScriptRoot\..\scripts\Invoke-DriftHalt.ps1"
}

Describe 'Invoke-DriftHalt — Layer 3' {

    Context 'Input parsing' {
        It 'parses drift rows from a resolver DRIFT_HALT message' {
            $msg = @"
DRIFT_HALT: canary inventory has 2 drift row(s); halt for owner approval / mitigation:
 - BOGUS-01: shortName not in resolved cloud
 - HUH-02: serviceTag mismatch
"@
            $r = & $script:driftHaltScript -ReleaseId '2026-05' -StepNumber 5 -StepName 'Canary' `
                -Scope canary -ResolverError $msg -SkipTeams -SkipStateUpdate
            $r.driftCount | Should -Be 2
            @($r.driftRows)[0].stampName | Should -Be 'BOGUS-01'
            @($r.driftRows)[0].reason    | Should -Be 'shortName not in resolved cloud'
            @($r.driftRows)[1].stampName | Should -Be 'HUH-02'
        }

        It 'accepts -DriftRows directly without parsing' {
            $rows = @(
                [pscustomobject]@{ stampName = 'X-01'; reason = 'fake'; source = 'test' }
                [pscustomobject]@{ stampName = 'Y-02'; reason = 'also fake'; source = 'test' }
            )
            $r = & $script:driftHaltScript -ReleaseId '2026-05' -StepNumber 5 -StepName 'Canary' `
                -Scope canary -DriftRows $rows -SkipTeams -SkipStateUpdate
            $r.driftCount | Should -Be 2
            @($r.driftRows).stampName | Should -Be @('X-01','Y-02')
        }

        It 'throws when neither -DriftRows nor -ResolverError is supplied' {
            { & $script:driftHaltScript -ReleaseId '2026-05' -StepNumber 5 -StepName 'Canary' -Scope canary -SkipTeams -SkipStateUpdate } |
                Should -Throw -ExpectedMessage '*requires either -DriftRows or -ResolverError*'
        }

        It 'throws when ResolverError contains no parseable drift lines' {
            { & $script:driftHaltScript -ReleaseId '2026-05' -StepNumber 5 -StepName 'Canary' `
                -Scope canary -ResolverError 'DRIFT_HALT: nothing parseable here' `
                -SkipTeams -SkipStateUpdate } |
                Should -Throw -ExpectedMessage '*could not derive any drift rows*'
        }
    }

    Context 'State + audit side effects' {
        BeforeEach {
            $script:releaseId = "test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $script:relDir    = Join-Path $TestDrive ".zed-agent/releases/$script:releaseId"
            New-Item -ItemType Directory -Path $script:relDir -Force | Out-Null
            $state = [pscustomobject]@{
                id          = $script:releaseId
                status      = 'in-progress'
                lastUpdated = '2026-05-01T00:00:00Z'
                steps       = @(
                    [pscustomobject]@{ number = 5; status = 'in-progress'; startedAt = '2026-05-24T00:00:00Z'; completedAt = $null }
                )
            }
            $state | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:relDir 'state.json') -Encoding UTF8 -NoNewline
            Push-Location $TestDrive
        }
        AfterEach { Pop-Location }

        It 'flips step to failed-drift, attaches driftPayload, writes audit row' {
            $rows = @([pscustomobject]@{ stampName = 'X-01'; reason = 'unknown layout'; source = 'asc-join' })
            $r = & $script:driftHaltScript -ReleaseId $script:releaseId -StepNumber 5 -StepName 'Canary' `
                -Scope canary -DriftRows $rows -SkipTeams
            $r.stateUpdated | Should -BeTrue
            $r.auditWritten | Should -BeTrue

            $state = Get-Content (Join-Path $script:relDir 'state.json') -Raw | ConvertFrom-Json
            $step5 = $state.steps | Where-Object number -eq 5
            $step5.status | Should -Be 'failed-drift'
            $step5.completedAt | Should -Not -BeNullOrEmpty
            $step5.driftPayload | Should -Not -BeNull
            $step5.driftPayload.count | Should -Be 1
            @($step5.driftPayload.rows)[0].stampName | Should -Be 'X-01'

            $audit = Get-Content (Join-Path $script:relDir 'audit.jsonl') -Raw
            $audit | Should -Match '"event":"drift-halt"'
            $audit | Should -Match '"step":5'
            $audit | Should -Match 'X-01'
        }
    }
}
