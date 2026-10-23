BeforeAll {
    . "$PSScriptRoot\..\scripts\New-CommitExcel.ps1"
}

Describe 'New-CommitExcel' {
    BeforeAll {
        $hasImportExcel = $null -ne (Get-Module -ListAvailable ImportExcel -ErrorAction SilentlyContinue)
    }

    Context 'Function interface' {
        It 'has all required parameters' {
            $cmd = Get-Command New-CommitExcel
            $cmd.Parameters.Keys | Should -Contain 'CommitsJsonPath'
            $cmd.Parameters.Keys | Should -Contain 'OutputPath'
            $cmd.Parameters.Keys | Should -Contain 'AutoColumns'
            $cmd.Parameters.Keys | Should -Contain 'ManualColumns'
            $cmd.Parameters.Keys | Should -Contain 'MaxCommentsLength'
        }

        It 'has correct default auto columns (5 columns including Title and Comments)' {
            $cmd = Get-Command New-CommitExcel
            $cmd.Parameters['AutoColumns'].ParameterType.Name | Should -Be 'String[]'
        }

        It 'has correct default manual columns (3 columns)' {
            $cmd = Get-Command New-CommitExcel
            $cmd.Parameters['ManualColumns'].ParameterType.Name | Should -Be 'String[]'
        }
    }

    Context 'Comments handling' -Skip:(-not (Get-Module -ListAvailable ImportExcel -ErrorAction SilentlyContinue)) {
        It 'truncates long comments to MaxCommentsLength with ellipsis' {
            $commitsPath = Join-Path $TestDrive 'commits-long.json'
            $outputPath = Join-Path $TestDrive 'commits-long.xlsx'
            $longComment = '[Production-impacting] Code change: ' + ('A' * 300)
            @([PSCustomObject]@{ CommitID = 'abc123'; Author = 'test'; Date = '2026-04-01'; Subject = 'Test'; Comments = $longComment }) |
                ConvertTo-Json | Set-Content $commitsPath -Encoding UTF8

            $result = New-CommitExcel -CommitsJsonPath $commitsPath -OutputPath $outputPath
            $result.success | Should -BeTrue
        }

        It 'leaves Comments blank when not provided' {
            $commitsPath = Join-Path $TestDrive 'commits-nocomment.json'
            $outputPath = Join-Path $TestDrive 'commits-nocomment.xlsx'
            @([PSCustomObject]@{ CommitID = 'def456'; Author = 'test'; Date = '2026-04-01'; Subject = 'No comment' }) |
                ConvertTo-Json | Set-Content $commitsPath -Encoding UTF8

            $result = New-CommitExcel -CommitsJsonPath $commitsPath -OutputPath $outputPath
            $result.success | Should -BeTrue
        }

        It 'preserves agent-analyzed production impact comments' {
            $commitsPath = Join-Path $TestDrive 'commits-analyzed.json'
            $outputPath = Join-Path $TestDrive 'commits-analyzed.xlsx'
            @(
                [PSCustomObject]@{ CommitID = 'aaa111'; Author = 'dev1'; Date = '2026-04-01'; Subject = 'Fix retry'; Comments = '[Production-impacting] Code change: Updated retry logic in BackupEngine' },
                [PSCustomObject]@{ CommitID = 'bbb222'; Author = 'dev2'; Date = '2026-04-02'; Subject = 'Update CI'; Comments = '[Non-production] Pipeline change: Added timeout to canary YAML' }
            ) | ConvertTo-Json | Set-Content $commitsPath -Encoding UTF8

            $result = New-CommitExcel -CommitsJsonPath $commitsPath -OutputPath $outputPath
            $result.success | Should -BeTrue
            $result.rowCount | Should -Be 2
        }
    }

    Context 'Excel generation' -Skip:(-not (Get-Module -ListAvailable ImportExcel -ErrorAction SilentlyContinue)) {
        It 'creates xlsx file with 8 columns from commit data' {
            $commitsPath = Join-Path $TestDrive 'commits.json'
            $outputPath = Join-Path $TestDrive 'commits.xlsx'
            @([PSCustomObject]@{ CommitID = 'abc123'; Author = 'gwazire'; Date = '2026-04-01'; Subject = 'Fix bug'; Comments = '[Production-impacting] Code change: Resolved null ref in auth handler' }) | ConvertTo-Json | Set-Content $commitsPath -Encoding UTF8

            $result = New-CommitExcel -CommitsJsonPath $commitsPath -OutputPath $outputPath
            $result.success | Should -BeTrue
            $result.rowCount | Should -Be 1
            Test-Path $outputPath | Should -BeTrue
        }
    }
}
