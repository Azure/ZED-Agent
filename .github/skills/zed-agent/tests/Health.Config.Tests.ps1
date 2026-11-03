#Requires -Modules Pester
<#
    releaseHealth configuration: Load-ServiceConfig validation (Group 11 fields) and
    Resolve-NotificationRecipients routing for release-health-* event keys (incl. shadow mode).
#>
BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..\scripts'
    $script:NewCfg = {
        param([hashtable]$ReleaseHealth, [string[]]$OnCall = @('oncall@contoso.com'), [switch]$NoSkill)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $zed = Join-Path $root '.github\skills\zed-agent'
        New-Item -ItemType Directory -Force -Path $zed | Out-Null
        if (-not $NoSkill) {
            $skill = Join-Path $root '.github\skills\svc-release-health'
            New-Item -ItemType Directory -Force -Path $skill | Out-Null
            'x' | Set-Content (Join-Path $skill 'SKILL.md'); '{}' | Set-Content (Join-Path $skill 'health-config.json')
        }
        $groups = [ordered]@{ permanent = @('team@contoso.com'); healthOnCall = $OnCall }
        $cfg = [ordered]@{
            service = @{ name = 'Svc'; displayName = 'Svc' }; serviceTreeIds = @{ safefly = 'x' }
            ado = @{ organization = 'o'; project = 'p'; repository = 'r' }
            kusto = @{ bvt = @{ cluster = 'c' }; canary = @{ cluster = 'c' } }; sharepoint = @{ sitePath = 's' }
            notifications = @{ groups = $groups; routing = @{ 'release-health' = @{ failure = @{ emailGroups = @('permanent', 'healthOnCall') } }; 'release-health-tripwire' = @{ failure = @{ emailGroups = @('healthOnCall') } } } }
            stepGates = @{}
        }
        if ($ReleaseHealth) { $cfg.releaseHealth = $ReleaseHealth }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $zed 'service-config.json')
        '{}' | Set-Content (Join-Path $zed 'pipeline-catalog.json')
        Join-Path $zed 'service-config.json'
    }
    $script:Load = { param($p) & (Join-Path $Scripts 'Load-ServiceConfig.ps1') -ServiceConfigPath $p }
}

Describe 'Load-ServiceConfig releaseHealth' {
    It 'accepts an enabled, scaffolded release health skill with an on-call group' {
        (& $Load (& $NewCfg @{ enabled = $true; mode = 'advisory'; skillPath = '.github/skills/svc-release-health' })).releaseHealth.mode | Should -Be 'advisory'
    }
    It 'ignores releaseHealth when disabled' {
        { & $Load (& $NewCfg @{ enabled = $false } -NoSkill) } | Should -Not -Throw
    }
    It 'rejects an unknown mode' {
        { & $Load (& $NewCfg @{ enabled = $true; mode = 'loud'; skillPath = '.github/skills/svc-release-health' }) } | Should -Throw '*mode*'
    }
    It 'requires the service skill files' {
        { & $Load (& $NewCfg @{ enabled = $true; mode = 'shadow'; skillPath = '.github/skills/svc-release-health' } -NoSkill) } | Should -Throw '*SKILL.md*'
    }
    It 'requires a non-empty healthOnCall group' {
        { & $Load (& $NewCfg @{ enabled = $true; mode = 'shadow'; skillPath = '.github/skills/svc-release-health' } -OnCall @()) } | Should -Throw '*healthOnCall*'
    }
    It 'accepts the release-health routing rows' {
        $c = & $Load (& $NewCfg $null)
        $c.notifications.routing.'release-health-tripwire'.failure.emailGroups | Should -Be 'healthOnCall'
    }
}

Describe 'Resolve-NotificationRecipients release-health keys' {
    BeforeAll {
        $script:Release = [pscustomobject]@{ releaseOwner = [pscustomobject]@{ email = 'owner@contoso.com' } }
        $script:Cfg = { param($mode) [pscustomobject]@{
            releaseHealth = [pscustomobject]@{ enabled = $true; mode = $mode }
            notifications = [pscustomobject]@{
                groups = [pscustomobject]@{ permanent = @('team@contoso.com'); healthOnCall = @('oncall@contoso.com') }
                routing = [pscustomobject]@{
                    'release-health' = [pscustomobject]@{ success = [pscustomobject]@{ emailGroups = @('permanent') }; failure = [pscustomobject]@{ emailGroups = @('permanent', 'healthOnCall') } }
                    'release-health-tripwire' = [pscustomobject]@{ failure = [pscustomobject]@{ emailGroups = @('healthOnCall') } } } } } }
        $script:Resolve = { param($key, $mode = 'advisory') & (Join-Path $Scripts 'Resolve-NotificationRecipients.ps1') -EventKey $key -Config (& $Cfg $mode) -Release $Release }
    }
    It 'sends NO-GO to the team and the on-call group' {
        $r = & $Resolve 'release-health-no-go'
        $r.EmailTo | Should -Contain 'oncall@contoso.com'
        $r.EmailTo | Should -Contain 'team@contoso.com'
        $r.EmailTo | Should -Contain 'owner@contoso.com'
    }
    It 'sends early warnings to the on-call group only (plus owner)' {
        $r = & $Resolve 'release-health-early-warning'
        $r.EmailTo | Should -Contain 'oncall@contoso.com'
        $r.EmailTo | Should -Not -Contain 'team@contoso.com'
    }
    It 'keeps unrouted outcomes (hold) and interim reports owner-only' {
        @((& $Resolve 'release-health-hold').EmailTo) | Should -Be @('owner@contoso.com')
        @((& $Resolve 'release-health-interim').EmailTo) | Should -Be @('owner@contoso.com')
    }
    It 'sends every health notification to the owner only in shadow mode' {
        @((& $Resolve 'release-health-no-go' 'shadow').EmailTo) | Should -Be @('owner@contoso.com')
        @((& $Resolve 'release-health-early-warning' 'shadow').EmailTo) | Should -Be @('owner@contoso.com')
    }
}
