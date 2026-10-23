<#
.SYNOPSIS
    Pester tests for revert bits: lib/SdsJsonLib.ps1 (position-preserving settings diff/edit) and
    Invoke-RevertBits.ps1 (Plan / Prepare against a throw-away git remote).
    (Also verified on the real BCM history: carrying BCMTeeWorkflowVersion + EnforceInterserviceClientAuthorizer
    from 2610 onto the 2609 commit reproduces the team's releases/rollback2610FixSecurityConfig file byte-for-byte.)
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\SdsJsonLib.ps1')
    $script:RevertScript = Join-Path $PSScriptRoot '..\scripts\Invoke-RevertBits.ps1'
    $script:SdsPath = 'src/Deployment/ServiceDatacenterSettingsConfig.json'

    function New-Sds {
        param([hashtable]$Default, [hashtable]$PublicCloud, [hashtable]$StampEa, [string]$NewLine = "`r`n", [switch]$Bom, [switch]$ExtraStamp)
        function Props([hashtable]$h, [string]$ind) {
            ($h.GetEnumerator() | Sort-Object Name | ForEach-Object { "$ind""$($_.Name)"": ""$($_.Value)""" }) -join ",$NewLine"
        }
        $stamps = @("          {$NewLine            ""StampId"": ""ea-01"",$NewLine            ""Resources"": [ {$NewLine              ""Id"": ""ServiceConfig"",$NewLine              ""Properties"": {$NewLine$(Props $StampEa '                ')$NewLine              }$NewLine            } ]$NewLine          }")
        if ($ExtraStamp) { $stamps += "          {$NewLine            ""StampId"": ""new-01"",$NewLine            ""Resources"": [ { ""Id"": ""ServiceConfig"", ""Properties"": { ""K"": ""v"" } } ]$NewLine          }" }
        $text = "{$NewLine  ""Version"": ""2022"",$NewLine  ""DefaultResources"": [$NewLine    {$NewLine      ""Id"": ""ServiceConfig"",$NewLine      ""Properties"": {$NewLine$(Props $Default '        ')$NewLine      }$NewLine    }$NewLine  ],$NewLine  ""CloudSettings"": [$NewLine    {$NewLine      ""CloudName"": ""Public"",$NewLine      ""Resources"": [ {$NewLine        ""Id"": ""ServiceConfig"",$NewLine        ""Properties"": {$NewLine$(Props $PublicCloud '          ')$NewLine        }$NewLine      } ],$NewLine      ""StampSettings"": [$NewLine$($stamps -join ",$NewLine")$NewLine      ]$NewLine    }$NewLine  ]$NewLine}$NewLine"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        if ($Bom) { $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $bytes }
        return , $bytes
    }

    $script:PrevDefault = [ordered]@{ 'App->A' = '1'; 'App->BCMTeeWorkflowVersion' = '21.0'; 'App->Gone' = 'x'; 'App->Same' = 's' }
    $script:CurDefault = [ordered]@{ 'App->A' = '2'; 'App->BCMTeeWorkflowVersion' = '22.0'; 'App->New' = 'n'; 'App->Same' = 's' }
}

Describe 'SdsJsonLib' {
    It 'labels scopes by CloudName / StampId / Id and formats them' {
        $s = Get-SdsSettings (New-Sds -Default @{ 'K' = '1' } -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' })
        $scopes = @($s.settings.Values.scope | Sort-Object -Unique)
        $scopes | Should -Contain '/DefaultResources[Id=ServiceConfig]/Properties'
        $scopes | Should -Contain '/CloudSettings[CloudName=Public]/Resources[Id=ServiceConfig]/Properties'
        $scopes | Should -Contain '/CloudSettings[CloudName=Public]/StampSettings[StampId=ea-01]/Resources[Id=ServiceConfig]/Properties'
        Format-SdsScope '/CloudSettings[CloudName=Public]/StampSettings[StampId=ea-01]/Resources[Id=ServiceConfig]/Properties' | Should -Be 'Cloud Public / Stamp ea-01'
        Format-SdsScope '/DefaultResources[Id=ServiceConfig]/Properties' | Should -Be 'Default'
    }

    It 'finds modified, added, removed settings and new scopes' {
        $prev = New-Sds -Default $PrevDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' }
        $cur = New-Sds -Default $CurDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '2' } -ExtraStamp
        $ch = Compare-SdsSettings $prev $cur 'f.json'
        $byKey = @{}; foreach ($c in $ch) { $byKey["$($c.kind)|$($c.scopeLabel)|$($c.key)"] = $c }
        $byKey.Keys | Should -Contain 'modified|Default|App->A'
        $byKey.Keys | Should -Contain 'modified|Default|App->BCMTeeWorkflowVersion'
        $byKey.Keys | Should -Contain 'added|Default|App->New'
        $byKey.Keys | Should -Contain 'removed|Default|App->Gone'
        $byKey.Keys | Should -Contain 'modified|Cloud Public / Stamp ea-01|S'
        @($ch | Where-Object kind -eq 'scope-added').Count | Should -Be 1
        $byKey['modified|Default|App->BCMTeeWorkflowVersion'].previous | Should -Be '"21.0"'
        $byKey['modified|Default|App->BCMTeeWorkflowVersion'].current | Should -Be '"22.0"'
    }

    It 'edits only the chosen value and keeps every other byte (CRLF + BOM)' -ForEach @(@{ nl = "`r`n"; bom = $true }, @{ nl = "`n"; bom = $false }) {
        $prev = New-Sds -Default $PrevDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' } -NewLine $nl -Bom:$bom
        $cur = New-Sds -Default $CurDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '2' } -NewLine $nl -Bom:$bom
        $pick = @(Compare-SdsSettings $prev $cur 'f.json' | Where-Object key -eq 'App->BCMTeeWorkflowVersion')
        $res = Invoke-SdsPreserve $prev $cur $pick
        $expected = [Text.Encoding]::UTF8.GetString($prev).Replace('"App->BCMTeeWorkflowVersion": "21.0"', '"App->BCMTeeWorkflowVersion": "22.0"')
        [Text.Encoding]::UTF8.GetString($res.bytes) | Should -Be $expected
        if ($bom) { $res.bytes[0] | Should -Be 0xEF }
    }

    It 'carrying every change reproduces the current settings exactly and stays valid JSON' {
        $prev = New-Sds -Default $PrevDefault -PublicCloud @{ 'C' = '1'; 'D' = '1' } -StampEa @{ 'S' = '1' }
        $cur = New-Sds -Default $CurDefault -PublicCloud @{ 'D' = '9' } -StampEa @{ 'S' = '2'; 'T' = 't' }
        $all = Compare-SdsSettings $prev $cur 'f.json'
        $res = Invoke-SdsPreserve $prev $cur $all
        { Test-SdsJson $res.bytes } | Should -Not -Throw
        @(Compare-SdsSettings $res.bytes $cur 'f.json' | Where-Object { $_.kind -in 'modified', 'added', 'removed' }).Count | Should -Be 0
    }

    It 'removes the first, a middle and the last member without breaking commas' -ForEach @(
        @{ drop = @('App->A') }, @{ drop = @('App->Gone') }, @{ drop = @('App->Same') }, @{ drop = @('App->A', 'App->BCMTeeWorkflowVersion') }
    ) {
        $prev = New-Sds -Default $PrevDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' }
        $keep = [ordered]@{}; foreach ($k in $PrevDefault.Keys) { if ($drop -notcontains $k) { $keep[$k] = $PrevDefault[$k] } }
        $cur = New-Sds -Default $keep -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' }
        $res = Invoke-SdsPreserve $prev $cur (Compare-SdsSettings $prev $cur 'f.json')
        { Test-SdsJson $res.bytes } | Should -Not -Throw
        @(Compare-SdsSettings $res.bytes $cur 'f.json').Count | Should -Be 0
    }

    It 'gives stable change ids' {
        $prev = New-Sds -Default $PrevDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' }
        $cur = New-Sds -Default $CurDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' }
        $a = Compare-SdsSettings $prev $cur 'f.json'; $b = Compare-SdsSettings $prev $cur 'f.json'
        ($a.id -join ',') | Should -Be ($b.id -join ',')
    }
}

Describe 'Invoke-RevertBits (temp git remote)' {
    BeforeAll {
        function Invoke-TGit([string]$Dir) {
            $a = $args
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $o = & git -C $Dir @a 2>&1; $c = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
            if ($c -ne 0) { throw "git $($a -join ' '): $($o -join ' ')" }
            , @($o | ForEach-Object { "$_" })
        }
        function New-Repo {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory $root | Out-Null
            $origin = Join-Path $root 'origin.git'; $work = Join-Path $root 'work'
            Invoke-TGit $root init -q --bare -b master $origin | Out-Null
            Invoke-TGit $root clone -q $origin $work 2>$null | Out-Null
            foreach ($kv in @(@('user.email', 'z@x.com'), @('user.name', 'ZED'), @('core.autocrlf', 'false'))) { Invoke-TGit $work config $kv[0] $kv[1] | Out-Null }
            Invoke-TGit $work checkout -q -b master | Out-Null
            $p = Join-Path $work $script:SdsPath; New-Item -ItemType Directory (Split-Path $p) -Force | Out-Null
            [IO.File]::WriteAllBytes($p, (New-Sds -Default $script:PrevDefault -PublicCloud @{ 'C' = '1' } -StampEa @{ 'S' = '1' }))
            Invoke-TGit $work add -A | Out-Null; Invoke-TGit $work commit -q -m 'release 2609' | Out-Null
            $prevSha = (Invoke-TGit $work rev-parse HEAD)[0]
            [IO.File]::WriteAllBytes($p, (New-Sds -Default $script:CurDefault -PublicCloud @{ 'C' = '7' } -StampEa @{ 'S' = '1' }))
            Invoke-TGit $work commit -q -am 'release 2610' | Out-Null
            $curSha = (Invoke-TGit $work rev-parse HEAD)[0]
            Invoke-TGit $work push -q origin master | Out-Null
            $cfg = Join-Path $root 'service-config.json'
            [ordered]@{
                ado = @{ organization = 'o'; project = 'p'; repository = 'r'; baseBranch = 'master' }
                revertBits = [ordered]@{ enabled = $true; branchTemplate = 'releases/bcm{{YYMM}}revert'; topicBranchTemplate = 'users/{ownerAlias}/bcm{{YYMM}}revert-config'; files = @($script:SdsPath); preserveAlways = @('App->BCMTeeWorkflowVersion') }
            } | ConvertTo-Json -Depth 5 | Set-Content $cfg
            return [pscustomobject]@{ Root = $root; Work = $work; Prev = $prevSha; Cur = $curSha; Cfg = $cfg }
        }
        function Invoke-RB($Repo, [string]$Action, [hashtable]$Extra = @{}) {
            $splat = @{ Action = $Action; ReleaseId = '2026-10'; RepoPath = $Repo.Work; ServiceConfigPath = $Repo.Cfg; OwnerAlias = 'owner'
                ReleaseFile = (Join-Path $Repo.Root 'none.json'); StateFile = (Join-Path $Repo.Root 'none.json'); PlanPath = (Join-Path $Repo.Root 'plan.json')
                PreviousCommit = $Repo.Prev; CurrentCommit = $Repo.Cur }
            foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
            & $script:RevertScript @splat
        }
    }

    It 'Plan numbers the changed settings and marks preserveAlways' {
        $r = New-Repo
        $p = Invoke-RB $r 'Plan'
        $p.Status | Should -Be 'planned'
        $p.RevertBranch | Should -Be 'releases/bcm2610revert'
        $p.TopicBranch | Should -Be 'users/owner/bcm2610revert-config'
        $numbered = @($p.Changes | Where-Object number)
        $numbered.Count | Should -Be 5   # A, BCMTeeWorkflowVersion, New, Gone, Cloud C
        @($numbered | Where-Object autoPreserve).key | Should -Be 'App->BCMTeeWorkflowVersion'
        Test-Path (Join-Path $r.Root 'plan.md') | Should -BeTrue
    }

    It 'Prepare creates the revert branch at the previous commit and a work branch carrying only the kept settings' {
        $r = New-Repo
        $p = Invoke-RB $r 'Plan'
        $n = @($p.Changes | Where-Object { $_.key -eq 'App->A' })[0].number
        $res = Invoke-RB $r 'Prepare' @{ Preserve = "$n" }
        $res.Status | Should -Be 'prepared'
        @($res.Applied.key | Sort-Object) | Should -Be @('App->A', 'App->BCMTeeWorkflowVersion')
        $heads = Invoke-TGit $r.Work ls-remote --heads origin
        ($heads | Where-Object { $_ -like '*refs/heads/releases/bcm2610revert' }) | Should -BeLike "$($r.Prev)*"
        ($heads | Where-Object { $_ -like '*refs/heads/users/owner/bcm2610revert-config' }) | Should -Not -BeNullOrEmpty
        Invoke-TGit $r.Work fetch -q origin | Out-Null
        $parent = (Invoke-TGit $r.Work rev-parse 'origin/users/owner/bcm2610revert-config^')[0]
        $parent | Should -Be $r.Prev
        $diff = Invoke-TGit $r.Work diff -U0 $r.Prev 'origin/users/owner/bcm2610revert-config'
        @($diff | Where-Object { $_ -match '^[+-]\s' }).Count | Should -Be 4   # two values changed, nothing else
        ($diff -join "`n") | Should -Match '\+\s+"App->BCMTeeWorkflowVersion": "22.0"'
        ($diff -join "`n") | Should -Not -Match 'App->New|App->Gone'
        $res.SummaryMarkdown | Should -Match 'App->BCMTeeWorkflowVersion'
        (Invoke-TGit $r.Work worktree list).Count | Should -Be 1
    }

    It 'is idempotent: a re-run reuses the branches' {
        $r = New-Repo
        $a = Invoke-RB $r 'Prepare' @{ Preserve = 'none' }
        $b = Invoke-RB $r 'Prepare' @{ Preserve = 'none' }
        $b.Status | Should -Be 'prepared'
        $b.HeadSha | Should -Be $a.HeadSha
    }

    It 'refuses an existing revert branch that does not contain the previous commit' {
        $r = New-Repo
        Invoke-TGit $r.Work checkout -q --orphan other | Out-Null
        Invoke-TGit $r.Work commit -q --allow-empty -m unrelated | Out-Null
        Invoke-TGit $r.Work push -q origin 'HEAD:refs/heads/releases/bcm2610revert' | Out-Null
        Invoke-TGit $r.Work checkout -q master | Out-Null
        { Invoke-RB $r 'Prepare' @{ Preserve = 'none' } } | Should -Throw '*does not contain the previous release commit*'
    }

    It 'DryRun pushes nothing' {
        $r = New-Repo
        $d = Invoke-RB $r 'Prepare' @{ Preserve = 'all'; DryRun = $true }
        $d.Status | Should -Be 'dry-run'
        @($d.Applied).Count | Should -Be 5
        @(Invoke-TGit $r.Work ls-remote --heads origin | Where-Object { $_ -match 'revert' }).Count | Should -Be 0
    }

    It 'rejects an unknown setting number' {
        $r = New-Repo
        { Invoke-RB $r 'Prepare' @{ Preserve = '42'; DryRun = $true } } | Should -Throw '*no setting number 42*'
    }

    It 'asks for the previous commit when it cannot be determined' {
        $r = New-Repo
        $p = Invoke-RB $r 'Plan' @{ PreviousCommit = $null }
        $p.Status | Should -Be 'needs-previous-commit'
    }
}

Describe 'revertBits config validation' {
    BeforeAll {
        $script:Loader = Join-Path $PSScriptRoot '..\scripts\Load-ServiceConfig.ps1'
        function Write-Cfg($RevertBits) {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $dir | Out-Null
            [ordered]@{
                service = @{ name = 'BCM'; displayName = 'BCM' }; serviceTreeIds = @{ safefly = 'x' }
                ado = @{ organization = 'o'; project = 'p'; repository = 'r'; branchPrefix = 'b'; baseBranch = 'master' }
                kusto = @{ bvt = @{ cluster = 'c' }; canary = @{ cluster = 'c' } }; sharepoint = @{ sitePath = '/s' }
                notifications = @{ groups = @{ permanent = @('a@b.c') }; routing = @{} }; stepGates = @{ x = $false }
                revertBits = $RevertBits
            } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'service-config.json')
            '{}' | Set-Content (Join-Path $dir 'pipeline-catalog.json')
            Join-Path $dir 'service-config.json'
        }
    }
    It 'accepts a valid block' { { & $Loader -ServiceConfigPath (Write-Cfg @{ enabled = $true; branchTemplate = 'releases/bcm{{YYMM}}revert'; files = @('a.json') }) } | Should -Not -Throw }
    It 'rejects a fixed branch name' { { & $Loader -ServiceConfigPath (Write-Cfg @{ enabled = $true; branchTemplate = 'releases/revert'; files = @('a.json') }) } | Should -Throw '*{{YYMM}}*' }
    It 'rejects missing files' { { & $Loader -ServiceConfigPath (Write-Cfg @{ enabled = $true; branchTemplate = 'releases/bcm{{YYMM}}revert'; files = @() }) } | Should -Throw '*revertBits.files*' }
    It 'routes revert-bits events to 7-rollback.halt' {
        $cfg = [pscustomobject]@{ notifications = [pscustomobject]@{ groups = [pscustomobject]@{ p = @('dl@x.com') }; routing = [pscustomobject]@{ '7-rollback' = [pscustomobject]@{ halt = [pscustomobject]@{ emailGroups = @('p') } } } } }
        $rel = [pscustomobject]@{ releaseOwner = [pscustomobject]@{ alias = 'o'; email = 'o@x.com' } }
        foreach ($k in 'revert-bits-select', 'revert-bits-pr-raised', 'revert-bits-bvt-ready') {
            (& (Join-Path $PSScriptRoot '..\scripts\Resolve-NotificationRecipients.ps1') -EventKey $k -Config $cfg -Release $rel).EmailTo | Should -Contain 'dl@x.com'
        }
    }
}
