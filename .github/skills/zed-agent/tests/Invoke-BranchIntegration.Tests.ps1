<#
.SYNOPSIS
    Pester tests for Invoke-BranchIntegration.ps1 (Step 2a RI / 2b FI).
    Builds a throw-away bare "origin" with master/develop and controlled commit
    timestamps, then verifies: up-to-date short-circuit, .config preservation
    (conflicted + clean + added files), newest-edit-wins per file (hunk level),
    modify/delete handling, push + reuse idempotency, and that the caller's
    checkout is never touched.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-BranchIntegration.ps1'

    function Invoke-TestGit {
        param([string]$Dir, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = & git -C $Dir @GitArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        if ($code -ne 0) { throw "git $($GitArgs -join ' ') failed: $($out -join "`n")" }
        return , @($out | ForEach-Object { "$_" })
    }

    function Set-File {
        param([string]$Dir, [string]$Path, [string]$Content)
        $full = Join-Path $Dir $Path
        $parent = Split-Path -Parent $full
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($full, $Content)
    }

    function New-Commit {
        param([string]$Dir, [string]$Message, [string]$Date)
        $env:GIT_AUTHOR_DATE = $Date; $env:GIT_COMMITTER_DATE = $Date
        try {
            Invoke-TestGit $Dir add -A --force | Out-Null
            Invoke-TestGit $Dir commit -q -m $Message | Out-Null
        } finally {
            Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        }
    }

    function New-TestRepo {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $origin = Join-Path $root 'origin.git'
        $work = Join-Path $root 'work'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Invoke-TestGit $root init -q --bare -b master $origin | Out-Null
        Invoke-TestGit $root clone -q $origin $work 2>$null | Out-Null
        Invoke-TestGit $work config user.email 'zed@example.com' | Out-Null
        Invoke-TestGit $work config user.name 'ZED Test' | Out-Null
        Invoke-TestGit $work config core.autocrlf false | Out-Null
        Invoke-TestGit $work checkout -q -b master | Out-Null
        return [pscustomobject]@{ Root = $root; Origin = $origin; Work = $work }
    }

    # Common history:
    #   base (master)            : .config/versions.xml=1.0, src/app.txt (3 lines), src/newer-src.txt, src/del.txt
    #   develop (from base)      : versions.xml=2.0 (dev), app.txt line1 edited (Jan 10), newer-src edited (Jan 5), del.txt modified
    #   master  (from base)      : versions.xml=1.1 (master), app.txt line1 edited (Jan 20), newer-src edited (Jan 25),
    #                              app.txt line3 edited (clean), .config/master-only.xml added, del.txt deleted,
    #                              .config/.inc/settings.xml changed cleanly
    function New-IntegrationScenario {
        $r = New-TestRepo
        $w = $r.Work
        # Mirrors BCM: .config is git-ignored but its files are tracked (force-added).
        Set-File $w '.gitignore' ".config`n"
        Set-File $w '.config/.inc/versions.xml' "<v>1.0</v>`n"
        Set-File $w '.config/.inc/settings.xml' "a=1`n"
        Set-File $w 'src/app.txt' "line1-base`nline2`nline3-base`n"
        Set-File $w 'src/newer-src.txt' "x-base`n"
        Set-File $w 'src/del.txt' "keep me`n"
        New-Commit $w 'base' '2026-01-01T00:00:00Z'
        Invoke-TestGit $w push -q origin master | Out-Null

        Invoke-TestGit $w checkout -q -b develop | Out-Null
        Set-File $w '.config/.inc/versions.xml' "<v>2.0-dev</v>`n"
        New-Commit $w 'dev version' '2026-01-02T00:00:00Z'
        Set-File $w 'src/newer-src.txt' "x-develop`n"
        New-Commit $w 'dev newer-src' '2026-01-05T00:00:00Z'
        Set-File $w 'src/app.txt' "line1-develop`nline2`nline3-base`n"
        New-Commit $w 'dev app line1' '2026-01-10T00:00:00Z'
        Set-File $w 'src/del.txt' "modified on develop`n"
        New-Commit $w 'dev modifies del' '2026-01-11T00:00:00Z'
        Invoke-TestGit $w push -q origin develop | Out-Null

        Invoke-TestGit $w checkout -q master | Out-Null
        Set-File $w '.config/.inc/versions.xml' "<v>1.1-master</v>`n"
        Set-File $w '.config/.inc/settings.xml' "a=master`n"
        Set-File $w '.config/master-only.xml' "<m/>`n"
        New-Commit $w 'master config' '2026-01-15T00:00:00Z'
        Set-File $w 'src/app.txt' "line1-master`nline2`nline3-master`n"
        New-Commit $w 'master app' '2026-01-20T00:00:00Z'
        Set-File $w 'src/newer-src.txt' "x-master`n"
        New-Commit $w 'master newer-src' '2026-01-03T00:00:00Z'
        Invoke-TestGit $w rm -q src/del.txt | Out-Null
        New-Commit $w 'master deletes del' '2026-01-04T00:00:00Z'
        Invoke-TestGit $w push -q origin master | Out-Null
        return $r
    }

    function Get-RemoteFile {
        param($Repo, [string]$Branch, [string]$Path)
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = & git -C $Repo.Work show "origin/${Branch}:$Path" 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        if ($code -ne 0) { return $null }
        return (@($out | ForEach-Object { "$_" }) -join "`n")
    }
}

Describe 'Invoke-BranchIntegration' {

    Context 'RI master -> develop with conflicts' {
        BeforeAll {
            $script:repo = New-IntegrationScenario
            Invoke-TestGit $repo.Work checkout -q develop | Out-Null
            Set-File $repo.Work 'scratch.txt' 'uncommitted local work'
            $script:res = & $ScriptPath -Direction RI -SourceBranch master -TargetBranch develop `
                -IntegrationBranch 'zed/test-ri' -RepoPath $repo.Work -Push `
                -ReportPath (Join-Path $repo.Root 'report\ri.json')
            Invoke-TestGit $repo.Work fetch -q origin '+refs/heads/zed/test-ri:refs/remotes/origin/zed/test-ri' | Out-Null
        }

        It 'reports merged and pushes the integration branch' {
            $res.status | Should -Be 'merged'
            $res.pushed | Should -BeTrue
            (Invoke-TestGit $repo.Work rev-parse 'origin/zed/test-ri')[0] | Should -Be $res.headSha
        }

        It 'creates a real merge commit with target first and source second parent' {
            $parents = (Invoke-TestGit $repo.Work rev-list --parents -n 1 'origin/zed/test-ri')[0] -split ' '
            $parents.Count | Should -Be 3
            $parents[1] | Should -Be $res.targetSha
            $parents[2] | Should -Be $res.sourceSha
        }

        It 'keeps develop .config for a conflicted file' {
            Get-RemoteFile $repo 'zed/test-ri' '.config/.inc/versions.xml' | Should -Be '<v>2.0-dev</v>'
            ($res.conflicts | Where-Object path -eq '.config/.inc/versions.xml').reason | Should -Be 'preserve-path'
        }

        It 'reverts a clean master change under .config and drops master-only .config files' {
            Get-RemoteFile $repo 'zed/test-ri' '.config/.inc/settings.xml' | Should -Be 'a=1'
            Get-RemoteFile $repo 'zed/test-ri' '.config/master-only.xml' | Should -BeNullOrEmpty
            $res.preservedFiles | Should -Contain '.config/.inc/settings.xml'
            $res.preservedFiles | Should -Contain '.config/master-only.xml'
        }

        It 'takes the newer side per file and keeps non-conflicting hunks' {
            # app.txt: master edited line1 later (Jan 20 > Jan 10) -> master line1; line3 clean from master
            Get-RemoteFile $repo 'zed/test-ri' 'src/app.txt' | Should -Be "line1-master`nline2`nline3-master"
            $c = $res.conflicts | Where-Object path -eq 'src/app.txt'
            $c.winner | Should -Be 'source'
            $c.resolution | Should -Be 'conflicting hunks from winner'
        }

        It 'keeps the target when the target edit is newer' {
            # newer-src.txt: develop Jan 5 > master Jan 3 -> develop wins
            Get-RemoteFile $repo 'zed/test-ri' 'src/newer-src.txt' | Should -Be 'x-develop'
            ($res.conflicts | Where-Object path -eq 'src/newer-src.txt').winner | Should -Be 'target'
        }

        It 'resolves modify/delete by newest commit and flags it for review' {
            # del.txt: develop modified Jan 11 > master deleted Jan 4 -> develop file kept
            Get-RemoteFile $repo 'zed/test-ri' 'src/del.txt' | Should -Be 'modified on develop'
            $res.reviewFiles | Should -Contain 'src/del.txt'
        }

        It 'writes JSON + markdown reports' {
            Test-Path (Join-Path $repo.Root 'report\ri.json') | Should -BeTrue
            $md = Get-Content (Join-Path $repo.Root 'report\ri.md') -Raw
            $md | Should -Match 'RI: master → develop'
            $md | Should -Match 'src/app.txt'
        }

        It 'does not touch the caller checkout' {
            (Invoke-TestGit $repo.Work rev-parse --abbrev-ref HEAD)[0] | Should -Be 'develop'
            Get-Content (Join-Path $repo.Work 'scratch.txt') -Raw | Should -Be 'uncommitted local work'
            (Invoke-TestGit $repo.Work worktree list).Count | Should -Be 1
            Invoke-TestGit $repo.Work branch --list 'zed/test-ri' | Should -BeNullOrEmpty
        }

        It 'reuses the pushed branch on re-run (idempotent)' {
            $again = & $ScriptPath -Direction RI -SourceBranch master -TargetBranch develop `
                -IntegrationBranch 'zed/test-ri' -RepoPath $repo.Work -Push
            $again.status | Should -Be 'reused'
            $again.headSha | Should -Be $res.headSha
        }
    }

    Context 'FI develop -> master keeps master .config' {
        It 'preserves the target (master) .config and merges develop' {
            $repo = New-IntegrationScenario
            $res = & $ScriptPath -Direction FI -SourceBranch develop -TargetBranch master `
                -IntegrationBranch 'zed/test-fi' -RepoPath $repo.Work -Push
            Invoke-TestGit $repo.Work fetch -q origin '+refs/heads/zed/test-fi:refs/remotes/origin/zed/test-fi' | Out-Null
            $res.status | Should -Be 'merged'
            Get-RemoteFile $repo 'zed/test-fi' '.config/.inc/versions.xml' | Should -Be '<v>1.1-master</v>'
            Get-RemoteFile $repo 'zed/test-fi' '.config/master-only.xml' | Should -Be '<m/>'
            # app.txt: master (target) Jan 20 is newer than develop Jan 10 -> master kept
            Get-RemoteFile $repo 'zed/test-fi' 'src/app.txt' | Should -Be "line1-master`nline2`nline3-master"
        }
    }

    Context 'Short-circuits and guards' {
        It 'returns up-to-date when the source is already merged into the target' {
            $repo = New-TestRepo
            Set-File $repo.Work 'a.txt' "a`n"
            New-Commit $repo.Work 'base' '2026-01-01T00:00:00Z'
            Invoke-TestGit $repo.Work push -q origin master | Out-Null
            Invoke-TestGit $repo.Work push -q origin 'master:develop' | Out-Null
            $res = & $ScriptPath -Direction RI -SourceBranch master -TargetBranch develop `
                -IntegrationBranch 'zed/noop' -RepoPath $repo.Work -Push
            $res.status | Should -Be 'up-to-date'
            $res.pushed | Should -BeFalse
            (Invoke-TestGit $repo.Work ls-remote --heads origin 'zed/noop') | Should -BeNullOrEmpty
        }

        It 'does not push without -Push (test-mode dry run) and reports no review files when only .config conflicts' {
            $repo = New-TestRepo
            Set-File $repo.Work '.gitignore' ".config`n"
            Set-File $repo.Work '.config/.inc/versions.xml' "<v>1</v>`n"
            New-Commit $repo.Work 'base' '2026-01-01T00:00:00Z'
            Invoke-TestGit $repo.Work push -q origin master | Out-Null
            Invoke-TestGit $repo.Work checkout -q -b develop | Out-Null
            Set-File $repo.Work '.config/.inc/versions.xml' "<v>dev</v>`n"
            New-Commit $repo.Work 'dev' '2026-01-02T00:00:00Z'
            Invoke-TestGit $repo.Work push -q origin develop | Out-Null
            Invoke-TestGit $repo.Work checkout -q master | Out-Null
            Set-File $repo.Work '.config/.inc/versions.xml' "<v>master</v>`n"
            New-Commit $repo.Work 'master' '2026-01-03T00:00:00Z'
            Invoke-TestGit $repo.Work push -q origin master | Out-Null

            $res = & $ScriptPath -Direction RI -SourceBranch master -TargetBranch develop `
                -IntegrationBranch 'zed/dry' -RepoPath $repo.Work -ReportPath (Join-Path $repo.Root 'dry.json')
            $res.status | Should -Be 'merged'
            $res.pushed | Should -BeFalse
            @($res.conflicts).Count | Should -Be 1
            @($res.reviewFiles).Count | Should -Be 0
            (Get-Content (Join-Path $repo.Root 'dry.md') -Raw) | Should -Not -Match 'Please review'
            (Invoke-TestGit $repo.Work ls-remote --heads origin 'zed/dry') | Should -BeNullOrEmpty
        }

        It 'throws when the remote integration branch exists without the source' {
            $repo = New-IntegrationScenario
            Invoke-TestGit $repo.Work push -q origin 'origin/develop:refs/heads/zed/stale' | Out-Null
            { & $ScriptPath -Direction RI -SourceBranch master -TargetBranch develop `
                -IntegrationBranch 'zed/stale' -RepoPath $repo.Work -Push } |
                Should -Throw '*already exists but does not contain*'
        }
    }
}

Describe 'ado.integration wiring' {
    BeforeAll {
        $script:LoaderPath   = Join-Path $PSScriptRoot '..\scripts\Load-ServiceConfig.ps1'
        $script:ResolverPath = Join-Path $PSScriptRoot '..\scripts\Resolve-NotificationRecipients.ps1'
        $script:WatcherPath  = Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1'
        $script:ColdPath     = Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1'

        function Write-ServiceConfig {
            param($Integration, [string]$BaseBranch = 'master')
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $ado = [ordered]@{ organization = 'msazure'; project = 'One'; repository = 'Repo'; branchPrefix = 'releases/x-'; baseBranch = $BaseBranch }
            if ($null -ne $Integration) { $ado.integration = $Integration }
            $cfg = [ordered]@{
                service        = @{ name = 'BCM'; displayName = 'BCM' }
                serviceTreeIds = @{ safefly = '00000000-0000-0000-0000-000000000000' }
                ado            = $ado
                kusto          = @{ bvt = @{ cluster = 'c' }; canary = @{ cluster = 'c' } }
                sharepoint     = @{ sitePath = '/sites/x' }
                notifications  = @{ groups = @{ permanent = @('dl@example.com') }; routing = @{} }
                stepGates      = @{ '2-cut-branch' = $false }
            }
            $cfg | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'service-config.json') -Encoding UTF8
            '{}' | Set-Content (Join-Path $dir 'pipeline-catalog.json') -Encoding UTF8
            return (Join-Path $dir 'service-config.json')
        }
    }

    Context 'Load-ServiceConfig validation' {
        It 'accepts a config without ado.integration' {
            { & $LoaderPath -ServiceConfigPath (Write-ServiceConfig -Integration $null) } | Should -Not -Throw
        }
        It 'accepts integration disabled even if branches are missing' {
            { & $LoaderPath -ServiceConfigPath (Write-ServiceConfig -Integration @{ enabled = $false }) } | Should -Not -Throw
        }
        It 'accepts a valid enabled integration block' {
            $p = Write-ServiceConfig -Integration @{ enabled = $true; developBranch = 'develop'; mainBranch = 'master'; preservePaths = @('.config') }
            $cfg = & $LoaderPath -ServiceConfigPath $p
            $cfg.ado.integration.developBranch | Should -Be 'develop'
        }
        It 'rejects mainBranch that differs from ado.baseBranch' {
            $p = Write-ServiceConfig -BaseBranch 'develop' -Integration @{ enabled = $true; developBranch = 'develop'; mainBranch = 'master' }
            { & $LoaderPath -ServiceConfigPath $p } | Should -Throw '*must equal ado.baseBranch*'
        }
        It 'rejects a missing developBranch' {
            $p = Write-ServiceConfig -Integration @{ enabled = $true; mainBranch = 'master' }
            { & $LoaderPath -ServiceConfigPath $p } | Should -Throw '*ado.integration.developBranch*'
        }
        It 'rejects an unsupported conflictStrategy' {
            $p = Write-ServiceConfig -Integration @{ enabled = $true; developBranch = 'develop'; mainBranch = 'master'; conflictStrategy = 'ours' }
            { & $LoaderPath -ServiceConfigPath $p } | Should -Throw '*conflictStrategy*'
        }
    }

    Context 'Notification event keys' {
        It 'routes <key> through 2-cut-branch.halt' -ForEach @(@{ key = 'ri-pr-raised' }, @{ key = 'fi-pr-raised' }) {
            $cfg = [pscustomobject]@{
                notifications = [pscustomobject]@{
                    groups  = [pscustomobject]@{ permanent = @('dl@example.com') }
                    routing = [pscustomobject]@{ '2-cut-branch' = [pscustomobject]@{ halt = [pscustomobject]@{ emailGroups = @('permanent') } } }
                }
            }
            $rel = [pscustomobject]@{ releaseOwner = [pscustomobject]@{ alias = 'o'; email = 'owner@example.com' } }
            $r = & $ResolverPath -EventKey $key -Config $cfg -Release $rel
            $r.EmailTo | Should -Contain 'dl@example.com'
            $r.EmailTo | Should -Contain 'owner@example.com'
            $r.Broadcast | Should -BeTrue
        }
    }

    Context 'Watcher + cold resume understand poll-ado-pr' {
        It 'watcher has a poll-ado-pr branch that handles completed and abandoned' {
            $content = Get-Content $WatcherPath -Raw
            $content | Should -Match "action -eq 'poll-ado-pr'"
            $content | Should -Match "status -eq 'completed'"
            $content | Should -Match "status -eq 'abandoned'"
        }
        It 'cold resume flags poll-ado-pr for live evaluation' {
            Get-Content $ColdPath -Raw | Should -Match "'poll-ado-pr'"
        }
    }
}
