<#
.SYNOPSIS
    Pester tests for release names (service-config.json → releaseNaming): several releases per
    month (BCM2610, BCM2610_2, BCM2610_3) where the name is the release id everywhere —
    lib\ReleaseNameLib.ps1, Resolve-ReleaseName.ps1, template expansion in the commit tracker /
    revert bits, and the Load-ServiceConfig guards.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\ReleaseNameLib.ps1')
    $script:Resolver = Join-Path $PSScriptRoot '..\scripts\Resolve-ReleaseName.ps1'
    $script:Loader = Join-Path $PSScriptRoot '..\scripts\Load-ServiceConfig.ps1'
    $script:Naming = Get-ReleaseNamingConfig ([pscustomobject]@{ releaseNaming = [pscustomobject]@{ prefix = 'BCM' } })

    function New-Repo([object[]]$Releases = @()) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory (Join-Path $root '.zed-agent/releases') -Force | Out-Null
        foreach ($r in $Releases) {
            $d = Join-Path $root ".zed-agent/releases/$($r.id)"
            New-Item -ItemType Directory $d -Force | Out-Null
            @{ releaseId = $r.id; testMode = [bool]$r.test; dates = @{ created = '2026-10-01T00:00:00Z' } } | ConvertTo-Json | Set-Content (Join-Path $d 'release.json')
            @{ status = $r.status } | ConvertTo-Json | Set-Content (Join-Path $d 'state.json')
        }
        @{ service = @{ name = 'BCM' }; releaseNaming = @{ prefix = 'BCM'; sequenceSeparator = '_' } } | ConvertTo-Json | Set-Content (Join-Path $root 'svc.json')
        return $root
    }
    function Invoke-R([string]$Root, [hashtable]$P) { & $script:Resolver @P -RepoRoot $Root -ServiceConfigPath (Join-Path $Root 'svc.json') }
}

Describe 'ReleaseNameLib' {
    It 'parses <name>' -ForEach @(
        @{ name = 'BCM2610'; canon = 'BCM2610'; month = '2026-10'; seq = 1 }
        @{ name = 'BCM2610_2'; canon = 'BCM2610_2'; month = '2026-10'; seq = 2 }
        @{ name = ' bcm2701_3 '; canon = 'BCM2701_3'; month = '2027-01'; seq = 3 }
    ) {
        $p = ConvertFrom-ReleaseName $name $script:Naming
        $p.releaseName | Should -BeExactly $canon
        $p.releaseMonth | Should -Be $month
        $p.sequence | Should -Be $seq
    }
    It 'rejects <name>' -ForEach @(
        @{ name = 'BCM2613' }, @{ name = 'BCM2610_1' }, @{ name = 'BCM261' }, @{ name = 'PROT2610' }, @{ name = 'BCM2610-2' }, @{ name = '2026-10' }
    ) {
        { ConvertFrom-ReleaseName $name $script:Naming } | Should -Throw
    }
    It 'rejects a bad prefix / separator' {
        { Get-ReleaseNamingConfig ([pscustomobject]@{ releaseNaming = [pscustomobject]@{ prefix = '1BC' } }) } | Should -Throw '*prefix*'
        { Get-ReleaseNamingConfig ([pscustomobject]@{ releaseNaming = [pscustomobject]@{ prefix = 'BCM'; sequenceSeparator = '#' } }) } | Should -Throw '*separator*'
        Get-ReleaseNamingConfig ([pscustomobject]@{ releaseNaming = [pscustomobject]@{ prefix = 'BCM'; enabled = $false } }) | Should -BeNullOrEmpty
        Get-ReleaseNamingConfig ([pscustomobject]@{ service = @{} }) | Should -BeNullOrEmpty
    }
    It 'finds the release month from releaseMonth, a YYYY-MM id, a test id or a release name' {
        (Get-ReleaseMonthParts 'BCM2610_2' ([pscustomobject]@{ releaseMonth = '2026-11' })).yymm | Should -Be '2611'
        (Get-ReleaseMonthParts '2026-10' $null).yymm | Should -Be '2610'
        (Get-ReleaseMonthParts 'TEST-2026-04-i3' $null).yymm | Should -Be '2604'
        (Get-ReleaseMonthParts 'BCM2610_2' $null).yymm | Should -Be '2610'
        { Get-ReleaseMonthParts 'whatever' $null } | Should -Throw '*release month*'
    }
    It 'expands the release tokens' {
        $rel = [pscustomobject]@{ releaseName = 'BCM2610_2'; releaseMonth = '2026-10'; releaseTag = 'bcm2610_2'; releaseOwner = @{ alias = 'agarwala' } }
        Expand-ReleaseTokens '{{releaseName}}' 'BCM2610_2' $rel | Should -BeExactly 'BCM2610_2'
        Expand-ReleaseTokens 'releases/{{releaseNameLower}}revert' 'BCM2610_2' $rel | Should -BeExactly 'releases/bcm2610_2revert'
        Expand-ReleaseTokens 'users/{ownerAlias}/{{releaseNameLower}}revert-config' 'BCM2610_2' $rel | Should -BeExactly 'users/agarwala/bcm2610_2revert-config'
        Expand-ReleaseTokens 'zed/{{releaseTag}}-ri' 'BCM2610_2' $rel | Should -BeExactly 'zed/bcm2610_2-ri'
        Expand-ReleaseTokens 'BCM{{YYMM}} {{YYYY}}-{{MM}} {{releaseId}}' 'BCM2610_2' $rel | Should -BeExactly 'BCM2610 2026-10 BCM2610_2'
        # without releaseNaming: the old YYYY-MM behaviour is unchanged
        Expand-ReleaseTokens 'releases/bcm{{YYMM}}revert' '2026-11' $null | Should -BeExactly 'releases/bcm2611revert'
        Expand-ReleaseTokens '{{releaseTag}}' '2026-11' ([pscustomobject]@{ currentBranch = 'releases/bcm-2611' }) | Should -BeExactly 'bcm-2611'
    }
    It 'gives the commit tracker one sheet per release' {
        . (Join-Path $PSScriptRoot '..\scripts\lib\CommitTrackerLib.ps1')
        Expand-SheetName '{{releaseName}}' 'BCM2610_2' ([pscustomobject]@{ releaseName = 'BCM2610_2'; releaseMonth = '2026-10' }) | Should -BeExactly 'BCM2610_2'
        Expand-SheetName 'BCM{{YYMM}}' '2026-11' | Should -BeExactly 'BCM2611'
        Expand-SheetName 'BCM{{YYMM}}' 'TEST-2026-04-i2' | Should -BeExactly 'BCM2604'
    }
}

Describe 'Resolve-ReleaseName' {
    It 'suggests <expected> when this month has <existing>' -ForEach @(
        @{ existing = @(); expected = 'BCM2610' }
        @{ existing = @('BCM2610'); expected = 'BCM2610_2' }
        @{ existing = @('BCM2610', 'BCM2610_2'); expected = 'BCM2610_3' }
        @{ existing = @('BCM2609', 'BCM2609_2', '2026-09'); expected = 'BCM2610' }
        @{ existing = @('2026-10'); expected = 'BCM2610_2' }
        @{ existing = @('2026-10', '2026-10-scrapped-20261017T045741Z', 'BCM2610_2'); expected = 'BCM2610_3' }
    ) {
        $root = New-Repo @($existing | ForEach-Object { @{ id = $_; status = 'completed' } })
        $r = Invoke-R $root @{ Action = 'Suggest'; Month = '2026-10' }
        $r.Success | Should -BeTrue
        $r.Suggested | Should -BeExactly $expected
        $r.ReleaseMonth | Should -Be '2026-10'
    }
    It 'lists still-active (non-test) releases so setup can stop them first' {
        $root = New-Repo @(@{ id = 'BCM2610'; status = 'in-progress' }, @{ id = 'BCM2609'; status = 'completed' }, @{ id = 'TEST-2026-10-i1'; status = 'in-progress'; test = $true })
        $r = Invoke-R $root @{ Action = 'Suggest'; Month = '2026-10' }
        @($r.Active) | Should -Be @('BCM2610')
        $r.Suggested | Should -BeExactly 'BCM2610_2'
    }
    It 'validates a name and reports whether it is free' {
        $root = New-Repo @(@{ id = 'BCM2610'; status = 'completed' })
        $r = Invoke-R $root @{ Action = 'Validate'; Name = 'bcm2610' }
        $r.Name | Should -BeExactly 'BCM2610'
        $r.Available | Should -BeFalse
        $r2 = Invoke-R $root @{ Action = 'Validate'; Name = 'BCM2610_2' }
        $r2.Available | Should -BeTrue
        $r2.Sequence | Should -Be 2
        $r2.ReleaseMonth | Should -Be '2026-10'
        $r3 = Invoke-R $root @{ Action = 'Validate'; Name = 'BCM2610_1' }
        $r3.Success | Should -BeFalse
        $r3.Error | Should -Match 'no suffix'
    }
    It 'treats a pre-releaseNaming release of the month (2026-10) as its first release' {
        $root = New-Repo @(@{ id = '2026-10'; status = 'in-progress' })
        $r = Invoke-R $root @{ Action = 'Validate'; Name = 'BCM2610' }
        $r.Available | Should -BeFalse
        @($r.Existing) | Should -Be @('2026-10 (= BCM2610)')
        (Invoke-R $root @{ Action = 'Validate'; Name = 'BCM2610_2' }).Available | Should -BeTrue
        @((Invoke-R $root @{ Action = 'Suggest'; Month = '2026-10' }).Active) | Should -Be @('2026-10')
    }
    It 'reports when releaseNaming is not configured' {
        $root = New-Repo
        @{ service = @{ name = 'X' } } | ConvertTo-Json | Set-Content (Join-Path $root 'svc.json')
        $r = Invoke-R $root @{ Action = 'Suggest' }
        $r.Success | Should -BeFalse
        $r.Enabled | Should -BeFalse
    }
}

Describe 'Load-ServiceConfig — releaseNaming guards' {
    BeforeAll {
        function Write-Cfg([hashtable]$Extra) {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $cfg = [ordered]@{
                service = @{ name = 'BCM'; displayName = 'BCM' }; serviceTreeIds = @{ safefly = 'x' }
                ado = @{ organization = 'o'; project = 'p'; repository = 'r'; branchPrefix = 'b'; baseBranch = 'master' }
                kusto = @{ bvt = @{ cluster = 'c' }; canary = @{ cluster = 'c' } }; sharepoint = @{ sitePath = '/s' }
                notifications = @{ groups = @{ permanent = @('a@b.c') }; routing = @{} }; stepGates = @{ x = $false }
            }
            foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
            $cfg | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'service-config.json')
            '{}' | Set-Content (Join-Path $dir 'pipeline-catalog.json')
            return (Join-Path $dir 'service-config.json')
        }
        $script:Tracker = @{ url = 'https://x'; columns = @(@{ header = 'L'; source = 'link' }, @{ header = 'R'; required = $true }) }
    }

    It 'accepts per-release templates' {
        $p = Write-Cfg @{
            releaseNaming = @{ prefix = 'BCM' }
            commitExcel = @{ mode = 'tracker'; sheetNameTemplate = '{{releaseName}}'; sharePointFolder = '/x'; excludeAuthors = @(); tracker = $script:Tracker }
            revertBits = @{ enabled = $true; branchTemplate = 'releases/{{releaseNameLower}}revert'; files = @('a.json') }
        }
        { & $script:Loader -ServiceConfigPath $p } | Should -Not -Throw
    }
    It 'rejects a {{YYMM}}-only <what> when several releases share a month' -ForEach @(
        @{ what = 'tracker sheet'; extra = @{ commitExcel = @{ mode = 'tracker'; sheetNameTemplate = 'BCM{{YYMM}}'; sharePointFolder = '/x'; excludeAuthors = @(); tracker = @{ url = 'https://x'; columns = @(@{ header = 'L'; source = 'link' }, @{ header = 'R'; required = $true }) } } }; msg = '*{{releaseName}}*' }
        @{ what = 'revert branch'; extra = @{ revertBits = @{ enabled = $true; branchTemplate = 'releases/bcm{{YYMM}}revert'; files = @('a.json') } }; msg = '*{{releaseNameLower}}*' }
    ) {
        $e = @{ releaseNaming = @{ prefix = 'BCM' } }; foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
        { & $script:Loader -ServiceConfigPath (Write-Cfg $e) } | Should -Throw $msg
    }
    It 'keeps accepting {{YYMM}} templates without releaseNaming, and rejects a bad prefix' {
        { & $script:Loader -ServiceConfigPath (Write-Cfg @{ revertBits = @{ enabled = $true; branchTemplate = 'releases/bcm{{YYMM}}revert'; files = @('a.json') } }) } | Should -Not -Throw
        { & $script:Loader -ServiceConfigPath (Write-Cfg @{ releaseNaming = @{ prefix = 'B C' } }) } | Should -Throw '*prefix*'
    }
}
