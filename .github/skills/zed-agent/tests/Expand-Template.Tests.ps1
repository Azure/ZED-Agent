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

        It 'throws by default when {{placeholders}} are missing from -Variables' {
            $tpl = Join-Path $TestDrive 'templates/partial.txt'
            '{{known}} and {{unknown}}' | Set-Content $tpl -Encoding UTF8
            { Expand-Template -TemplatePath $tpl -Variables @{ known = 'yes' } } |
                Should -Throw -ExpectedMessage '*unsubstituted placeholders*{{unknown}}*'
        }

        It 'leaves unrecognized {{placeholders}} unchanged when -StrictPlaceholders:$false' {
            $tpl = Join-Path $TestDrive 'templates/partial-lenient.txt'
            '{{known}} and {{unknown}}' | Set-Content $tpl -Encoding UTF8
            $result = Expand-Template -TemplatePath $tpl -Variables @{ known = 'yes' } -StrictPlaceholders:$false
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

    Context '{{releaseLabel}} default (service.releaseLabel, else BDP)' {
        BeforeEach {
            $script:Svc = Join-Path $TestDrive 'service-config.json'
            @{ service = @{ name = 'BCM'; displayName = 'BCM'; releaseLabel = 'BCM' } } | ConvertTo-Json | Set-Content $script:Svc -Encoding UTF8
        }

        It 'fills {{releaseLabel}} from service.releaseLabel when the caller does not pass it' {
            $tpl = Join-Path $TestDrive 'templates/svc.txt'
            '🔔 {{releaseLabel}} Release Branch Cut Reminder {{releaseId}}' | Set-Content $tpl -Encoding UTF8
            $vars = @{ releaseId = '2026-11' }
            Expand-Template -TemplatePath $tpl -Variables $vars -ServiceConfigPath $script:Svc | Should -Be '🔔 BCM Release Branch Cut Reminder 2026-11'
            $vars.ContainsKey('releaseLabel') | Should -BeFalse   # caller's hashtable is not modified
        }

        It 'defaults to BDP (unchanged messages) without service.releaseLabel or service-config, and an explicit value wins' {
            $tpl = Join-Path $TestDrive 'templates/svc2.txt'
            '{{releaseLabel}}' | Set-Content $tpl -Encoding UTF8
            @{ service = @{ name = 'Prot'; displayName = 'Protection Service' } } | ConvertTo-Json | Set-Content $script:Svc -Encoding UTF8
            Expand-Template -TemplatePath $tpl -Variables @{} -ServiceConfigPath $script:Svc | Should -BeExactly 'BDP'
            Expand-Template -TemplatePath $tpl -Variables @{} -ServiceConfigPath (Join-Path $TestDrive 'none.json') | Should -BeExactly 'BDP'
            Expand-Template -TemplatePath $tpl -Variables @{ releaseLabel = 'X' } -ServiceConfigPath $script:Svc | Should -Be 'X'
        }

        It 'does not auto-fill {{serviceName}} (callers pass it, as before)' {
            $tpl = Join-Path $TestDrive 'templates/svc3.txt'
            '{{serviceName}}' | Set-Content $tpl -Encoding UTF8
            { Expand-Template -TemplatePath $tpl -Variables @{} -ServiceConfigPath $script:Svc } | Should -Throw '*{{serviceName}}*'
        }
    }

    Context 'Shipped templates' {
        It 'no template hardcodes a service name (use {{releaseLabel}})' {
            $hits = Get-ChildItem (Join-Path $PSScriptRoot '..\templates') -File | Select-String -Pattern '\bBDP\b' -CaseSensitive
            @($hits).Count | Should -Be 0
        }
        It 'renders the release message templates exactly as before for a service without releaseLabel' {
            $cfg = Join-Path $TestDrive 'prot.json'
            @{ service = @{ name = 'Prot'; displayName = 'Protection Service' } } | ConvertTo-Json | Set-Content $cfg -Encoding UTF8
            $out = Expand-Template -TemplatePath (Join-Path $PSScriptRoot '..\templates\reminder-message.html') -Variables @{} -StrictPlaceholders:$false -ServiceConfigPath $cfg
            $out | Should -Match '🔔 BDP Release Branch Cut Reminder'
        }
    }
}
