<#
.SYNOPSIS
    Pester tests for Get-PreviousBranch.ps1 (lives in zed-forge/scripts).
    Exercises branch detection, YYMM filtering, prefix auto-detection, and edge cases.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\zed-forge\scripts\Get-PreviousBranch.ps1'
}

Describe 'Get-PreviousBranch' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

        # Initialise a bare git repo so we can add remote branches
        Push-Location $testRoot
        git init --quiet
        git commit --allow-empty -m 'init' --quiet
    }

    AfterEach {
        Pop-Location
    }

    Context 'BranchPrefix supplied explicitly — no service-config.json needed' {

        It 'returns the most recent YYMM branch that is not the current month' {
            git branch 'releases/prot2606' --quiet
            git branch 'releases/prot2607' --quiet
            git branch 'releases/prot2608' --quiet

            # Mock remote by using local repo as its own origin
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -BranchPrefix 'releases/prot' `
                -CurrentYYMM '2608'

            $result | Should -Be 'releases/prot2607'
        }

        It 'returns the single available branch when only one non-current exists' {
            git branch 'releases/prot2607' --quiet
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -BranchPrefix 'releases/prot' `
                -CurrentYYMM '2608'

            $result | Should -Be 'releases/prot2607'
        }

        It 'returns null and warns when no branches match prefix at all' {
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -BranchPrefix 'releases/prot' `
                -CurrentYYMM '2608' `
                -WarningAction SilentlyContinue

            $result | Should -BeNullOrEmpty
        }

        It 'excludes branches with suffixes (_hotfix, _az, _rollback) from results' {
            git branch 'releases/prot2607' --quiet
            git branch 'releases/prot2607_hotfix' --quiet
            git branch 'releases/prot2607_az' --quiet
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -BranchPrefix 'releases/prot' `
                -CurrentYYMM '2608'

            $result | Should -Be 'releases/prot2607'
        }

        It 'falls back to most-recent branch with warning when all branches match current month' {
            git branch 'releases/prot2608' --quiet
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $warnings = @()
            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -BranchPrefix 'releases/prot' `
                -CurrentYYMM '2608' `
                -WarningVariable warnings `
                -WarningAction SilentlyContinue

            $result | Should -Be 'releases/prot2608'
            $warnings | Should -Not -BeNullOrEmpty
        }
    }

    Context 'BranchPrefix auto-detected from service-config.json' {

        It 'reads branchPrefix from service-config.json and uses it' {
            # Create .github/skills/zed-agent/service-config.json
            $cfgDir = Join-Path $testRoot '.github\skills\zed-agent'
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
            @{ ado = @{ branchPrefix = 'releases/svc' } } |
                ConvertTo-Json | Set-Content (Join-Path $cfgDir 'service-config.json') -Encoding UTF8

            git branch 'releases/svc2607' --quiet
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -CurrentYYMM '2608'

            $result | Should -Be 'releases/svc2607'
        }

        It 'defaults to releases/prot with a warning when branchPrefix absent from service-config' {
            $cfgDir = Join-Path $testRoot '.github\skills\zed-agent'
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
            @{ ado = @{ org = 'msazure' } } |
                ConvertTo-Json | Set-Content (Join-Path $cfgDir 'service-config.json') -Encoding UTF8

            git branch 'releases/prot2607' --quiet
            git remote add origin $testRoot 2>$null
            git fetch origin --quiet 2>$null

            $warnings = @()
            $result = & $script:ScriptPath `
                -TargetRepo $testRoot `
                -CurrentYYMM '2608' `
                -WarningVariable warnings `
                -WarningAction SilentlyContinue

            $result | Should -Be 'releases/prot2607'
            $warnings | Where-Object { $_ -like '*branchPrefix*' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'TargetRepo validation' {

        It 'throws when TargetRepo path does not exist' {
            { & $script:ScriptPath `
                -TargetRepo 'C:\nonexistent\repo' `
                -BranchPrefix 'releases/prot' `
                -CurrentYYMM '2608' } |
                Should -Throw '*not found*'
        }
    }
}
