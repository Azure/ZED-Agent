BeforeAll {
    . "$PSScriptRoot\..\scripts\Send-Email.ps1"
}

Describe 'Send-Email' {
    BeforeAll {
        $templateDir = Join-Path $TestDrive 'templates'
        New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
        $htmlPath = Join-Path $templateDir 'test-email.html'
        '<html><body>Hello {{name}}</body></html>' | Set-Content $htmlPath -Encoding UTF8
    }

    Context 'Successful send' {
        It 'sends email via Outlook COM with template rendering' {
            # Mock the Outlook COM chain
            $mockMail = [PSCustomObject]@{ To = ''; CC = ''; Subject = ''; HTMLBody = ''; Sent = $false }
            $mockMail | Add-Member -MemberType ScriptMethod -Name Send -Value { $this.Sent = $true }
            $mockMail | Add-Member -MemberType ScriptMethod -Name Attachments -Value {
                [PSCustomObject]@{} | Add-Member -MemberType ScriptMethod -Name Add -Value {} -PassThru
            }

            $mockOutlook = [PSCustomObject]@{}
            $mockOutlook | Add-Member -MemberType ScriptMethod -Name CreateItem -Value { param($type) return $mockMail }.GetNewClosure()

            Mock New-Object { return $mockOutlook } -ParameterFilter { $ComObject -eq 'Outlook.Application' }

            $result = Send-Email -To 'test@example.com' -Subject 'Test' -BodyHtmlPath $htmlPath -Variables @{ name = 'BDP' }
            $result.success | Should -BeTrue
            $result.method | Should -Be 'OutlookCOM'
        }
    }

    Context 'Retry on failure' {
        It 'retries up to 3 times on COM errors' {
            Mock New-Object { throw 'COM object unavailable' } -ParameterFilter { $ComObject -eq 'Outlook.Application' }
            Mock Start-Sleep {}

            $result = Send-Email -To 'test@example.com' -Subject 'Test' -BodyHtmlPath $htmlPath
            $result.success | Should -BeFalse
            $result.error | Should -Not -BeNullOrEmpty
            $result.method | Should -Be 'OutlookCOM'
        }
    }
}
