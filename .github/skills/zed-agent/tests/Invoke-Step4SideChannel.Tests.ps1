BeforeAll {
    $script:sideChannelScript = "$PSScriptRoot\..\scripts\Invoke-Step4SideChannel.ps1"
    . "$PSScriptRoot\..\scripts\Invoke-WithStateLock.ps1"
}

Describe 'Invoke-Step4SideChannel' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive 'repo'
        $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
        New-Item -ItemType Directory -Path $relDir -Force | Out-Null
        Push-Location $testRoot

        $script:stateFile = Join-Path $relDir 'state.json'
        $script:auditFile = Join-Path $relDir 'audit.jsonl'
        $script:lockFile = Join-Path $relDir 'state.json.lock'
    }

    AfterEach { Pop-Location }

    Context 'Step 4 not eligible' {
        It 'returns Success=true when step4InlineCompleted is false (nothing to do)' {
            $state = @{
                releaseId = '2026-04'; step4InlineCompleted = $false
                steps = @( @{ number = 4; status = 'pending' } )
                lastUpdated = (Get-Date -Format 'o')
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content $script:stateFile -Encoding UTF8

            $result = & $script:sideChannelScript -ReleaseId '2026-04' `
                -StateFile $script:stateFile -StateLock $script:lockFile -AuditFile $script:auditFile

            $result.Success | Should -BeTrue
            $result.StepCompleted | Should -BeFalse
        }
    }

    Context 'Step 4 already completed' {
        It 'returns Success=true when step4 status is completed (nothing to do)' {
            $state = @{
                releaseId = '2026-04'; step4InlineCompleted = $true
                step4ExcelUrl = 'https://example.com/file.xlsx'
                steps = @( @{ number = 4; status = 'completed'; completedAt = (Get-Date -Format 'o') } )
                lastUpdated = (Get-Date -Format 'o')
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content $script:stateFile -Encoding UTF8

            $result = & $script:sideChannelScript -ReleaseId '2026-04' `
                -StateFile $script:stateFile -StateLock $script:lockFile -AuditFile $script:auditFile

            $result.Success | Should -BeTrue
            $result.StepCompleted | Should -BeFalse
        }
    }

    Context 'No access token' {
        It 'returns Error when no AccessToken provided and az CLI fails' {
            $state = @{
                releaseId = '2026-04'; step4InlineCompleted = $true
                step4ExcelUrl = 'https://example.com/file.xlsx'
                steps = @( @{ number = 4; status = 'in-progress' } )
                lastUpdated = (Get-Date -Format 'o')
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content $script:stateFile -Encoding UTF8

            # Mock az CLI to fail by providing no AccessToken param
            $result = & $script:sideChannelScript -ReleaseId '2026-04' `
                -StateFile $script:stateFile -StateLock $script:lockFile -AuditFile $script:auditFile

            $result.Success | Should -BeFalse
            $result.Error | Should -Not -BeNullOrEmpty
        }
    }
}
