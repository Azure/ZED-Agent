BeforeAll {
    . "$PSScriptRoot\..\scripts\Send-TeamsMessage.ps1"
}

Describe 'Send-TeamsMessage' {
    BeforeAll {
        $templateDir = Join-Path $TestDrive 'templates'
        New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
        $templatePath = Join-Path $templateDir 'test-message.html'
        '<b>Hello {{name}}</b><br>Release {{releaseId}} is ready.' | Set-Content $templatePath -Encoding UTF8

        # Mock the Teams-ChatHelper functions
        Mock Get-TeamsSkypeToken { return 'mock-skype-token-123' }
    }

    Context 'Successful send via CDP + Skype token' {
        It 'sends HTML message and returns success' {
            Mock Invoke-RestMethod { return @{ OriginalArrivalTime = '2025-01-15T10:00:00Z' } }
            $result = Send-TeamsMessage -ConversationId '19:abc123@thread.v2' -TemplatePath $templatePath -Variables @{ name = 'BDP'; releaseId = '2025-01' }
            $result.success | Should -BeTrue
            $result.method | Should -Be 'CDP+SkypeToken'
            Should -Invoke Invoke-RestMethod -Times 1
        }

        It 'substitutes template variables in message body' {
            $script:capturedBody = $null
            Mock Invoke-RestMethod { param($Body) $script:capturedBody = $Body; return @{ OriginalArrivalTime = '2025-01-15T10:00:00Z' } }
            Send-TeamsMessage -ConversationId '19:abc123@thread.v2' -TemplatePath $templatePath -Variables @{ name = 'World'; releaseId = '2025-02' }
            $script:capturedBody | Should -Match 'World'
            $script:capturedBody | Should -Match '2025-02'
        }

        It 'sends raw HTML body without template' {
            Mock Invoke-RestMethod { return @{ OriginalArrivalTime = '2025-01-15T10:00:00Z' } }
            $result = Send-TeamsMessage -ConversationId '19:abc123@thread.v2' -Body '<b>Direct HTML</b>'
            $result.success | Should -BeTrue
        }
    }

    Context 'Error handling' {
        It 'returns error when neither TemplatePath nor Body provided' {
            $result = Send-TeamsMessage -ConversationId '19:abc123@thread.v2'
            $result.success | Should -BeFalse
            $result.error | Should -Match 'Either -TemplatePath or -Body must be provided'
        }

        It 'retries on HTTP 429 and eventually fails' {
            Mock Invoke-RestMethod { throw [System.Net.WebException]::new('Service unavailable') }
            Mock Start-Sleep {}
            $result = Send-TeamsMessage -ConversationId '19:abc123@thread.v2' -Body '<b>Test</b>'
            $result.success | Should -BeFalse
            $result.method | Should -Be 'CDP+SkypeToken'
        }
    }
}
