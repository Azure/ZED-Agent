BeforeAll {
    . "$PSScriptRoot\..\scripts\Upload-ToSharePoint.ps1"
}

Describe 'Upload-ToSharePoint' {
    Context 'Function interface' {
        It 'has all required parameters' {
            $cmd = Get-Command Upload-ToSharePoint
            $cmd.Parameters.Keys | Should -Contain 'FilePath'
            $cmd.Parameters.Keys | Should -Contain 'SiteId'
            $cmd.Parameters.Keys | Should -Contain 'TargetFolder'
            $cmd.Parameters.Keys | Should -Contain 'FileName'
        }
    }

    Context 'Successful upload' {
        It 'uploads file and returns sharing link' {
            $testFile = Join-Path $TestDrive 'test.xlsx'
            [byte[]]$bytes = @(0x50, 0x4B, 0x03, 0x04)
            [IO.File]::WriteAllBytes($testFile, $bytes)

            Mock az { return '"mock-token"' }
            Mock Invoke-RestMethod {
                param($Uri, $Method)
                if ($Method -eq 'Put') {
                    return [PSCustomObject]@{ id = 'item-123'; lastModifiedDateTime = '2026-04-01T10:00:00Z' }
                }
                if ($Method -eq 'Post') {
                    return [PSCustomObject]@{ link = [PSCustomObject]@{ webUrl = 'https://share.example/link' } }
                }
            }

            $result = Upload-ToSharePoint -FilePath $testFile -SiteId 'site-id' -TargetFolder 'Commits'
            $result.success | Should -BeTrue
            $result.webUrl | Should -Be 'https://share.example/link'
            $result.driveItemId | Should -Be 'item-123'
        }

        It 'uses az account get-access-token for Graph API auth' {
            $testFile = Join-Path $TestDrive 'test2.xlsx'
            [byte[]]$bytes = @(0x50, 0x4B)
            [IO.File]::WriteAllBytes($testFile, $bytes)

            Mock az { return '"mock-token"' } -Verifiable
            Mock Invoke-RestMethod { [PSCustomObject]@{ id = 'x'; lastModifiedDateTime = '' } }

            Upload-ToSharePoint -FilePath $testFile -SiteId 'site-id' -TargetFolder 'Commits'
            Should -InvokeVerifiable
        }
    }

    Context 'Retry on failure' {
        It 'retries up to 3 times on transient error' {
            $testFile = Join-Path $TestDrive 'test3.xlsx'
            [byte[]]$bytes = @(0x50)
            [IO.File]::WriteAllBytes($testFile, $bytes)

            Mock az { return '"mock-token"' }
            Mock Invoke-RestMethod { throw 'Service unavailable' }
            Mock Start-Sleep {}

            $result = Upload-ToSharePoint -FilePath $testFile -SiteId 'site-id' -TargetFolder 'Commits'
            $result.success | Should -BeFalse
            $result.error | Should -Not -BeNullOrEmpty
        }
    }
}
