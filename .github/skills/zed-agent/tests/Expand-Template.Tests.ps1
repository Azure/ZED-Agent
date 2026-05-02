BeforeAll {
    . "$PSScriptRoot\..\scripts\Expand-Template.ps1"
}

Describe 'Expand-Template' {
    BeforeEach {
        $templateDir = Join-Path $TestDrive 'templates'
        New-Item -ItemType Directory -Path $templateDir -Force | Out-Null
    }

    Context 'Variable substitution' {
        It 'replaces {{variable}} placeholders with values' {
            $tpl = Join-Path $TestDrive 'templates/test.txt'
            'Hello {{name}}, welcome to {{project}}!' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ name = 'Gireeraj'; project = 'BDP' }
            $result | Should -Be 'Hello Gireeraj, welcome to BDP!'
        }

        It 'leaves unrecognized {{placeholders}} from missing keys unchanged' {
            $tpl = Join-Path $TestDrive 'templates/partial.txt'
            '{{known}} and {{unknown}}' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ known = 'yes' }
            $result | Should -Be 'yes and {{unknown}}'
        }

        It 'handles empty string values' {
            $tpl = Join-Path $TestDrive 'templates/empty.txt'
            'Value: {{val}}' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ val = '' }
            $result | Should -Be 'Value: '
        }
    }

    Context 'Conditional sections' {
        It 'includes {{#section}} block when variable is truthy' {
            $tpl = Join-Path $TestDrive 'templates/cond.txt'
            'Start{{#show}} VISIBLE{{/show}} End' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ show = $true }
            $result | Should -Be 'Start VISIBLE End'
        }

        It 'removes {{#section}} block when variable is falsy' {
            $tpl = Join-Path $TestDrive 'templates/cond2.txt'
            'Start{{#hide}} HIDDEN{{/hide}} End' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ hide = $false }
            $result | Should -Be 'Start End'
        }

        It 'removes undefined conditional blocks entirely' {
            $tpl = Join-Path $TestDrive 'templates/undef.txt'
            'Before{{#missing}}content{{/missing}}After' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{}
            $result | Should -Be 'BeforeAfter'
        }

        It 'handles string truthy (non-empty = true)' {
            $tpl = Join-Path $TestDrive 'templates/strtrue.txt'
            '{{#name}}Hello {{name}}{{/name}}' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ name = 'Test' }
            $result | Should -Be 'Hello Test'
        }
    }

    Context 'JSON template rendering' {
        It 'renders a JSON Adaptive Card template with variables' {
            $tpl = Join-Path $TestDrive 'templates/card.json'
            '{"text":"Release {{releaseId}} by {{releaseOwner}}"}' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ releaseId = '2026-04'; releaseOwner = 'gwazire' }
            $parsed = $result | ConvertFrom-Json
            $parsed.text | Should -Be 'Release 2026-04 by gwazire'
        }
    }
}
