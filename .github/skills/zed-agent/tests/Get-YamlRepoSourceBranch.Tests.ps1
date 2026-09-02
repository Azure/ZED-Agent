<#
.SYNOPSIS
    Pester tests for Get-YamlRepoSourceBranch.ps1.
    Covers happy-path resolution, and all three fail-loud paths (missing yamlRepos
    block, missing repo key, empty baseBranch).
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Get-YamlRepoSourceBranch.ps1'

    function New-Catalog {
        param([hashtable]$YamlRepos)
        $catalog = @{
            canary     = @{}
            production = @{}
        }
        if ($null -ne $YamlRepos) {
            $catalog['yamlRepos'] = $YamlRepos
        }
        return $catalog
    }

    function Write-CatalogFile {
        param([hashtable]$YamlRepos, [string]$Dir)
        $path = Join-Path $Dir 'pipeline-catalog.json'
        New-Catalog -YamlRepos $YamlRepos | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
        return $path
    }
}

Describe 'Get-YamlRepoSourceBranch' {
    BeforeEach {
        $testDir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    Context 'Happy path — returns correct refs/heads/<baseBranch>' {
        It 'returns refs/heads/develop when baseBranch is develop' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'MyRepo' = @{ baseBranch = 'develop' }
            } -Dir $testDir

            $result = & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'MyRepo'
            $result | Should -Be 'refs/heads/develop'
        }

        It 'returns refs/heads/main when baseBranch is main' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'AnotherRepo' = @{ baseBranch = 'main' }
            } -Dir $testDir

            $result = & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'AnotherRepo'
            $result | Should -Be 'refs/heads/main'
        }

        It 'works with the expected service repo name' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'Mgmt-RecoverySvcs-BackupDataPlane' = @{ baseBranch = 'develop' }
            } -Dir $testDir

            $result = & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'Mgmt-RecoverySvcs-BackupDataPlane'
            $result | Should -Be 'refs/heads/develop'
        }

        It 'handles extra yamlRepos keys beyond the requested one' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'RepoA' = @{ baseBranch = 'develop' }
                'RepoB' = @{ baseBranch = 'main' }
            } -Dir $testDir

            $result = & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'RepoB'
            $result | Should -Be 'refs/heads/main'
        }
    }

    Context 'Fail-loud: catalog file missing' {
        It 'throws if catalog file does not exist' {
            { & $script:ScriptPath -CatalogPath 'C:\nonexistent\pipeline-catalog.json' -RepoName 'Any' } |
                Should -Throw '*catalog file not found*'
        }
    }

    Context 'Fail-loud: yamlRepos block missing' {
        It 'throws with actionable message when yamlRepos is absent from catalog' {
            $catalogPath = Write-CatalogFile -YamlRepos $null -Dir $testDir

            { & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'SomeRepo' } |
                Should -Throw "*'yamlRepos' block is missing*"
        }

        It 'error message names the repo key for easy remediation' {
            $catalogPath = Write-CatalogFile -YamlRepos $null -Dir $testDir

            { & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'TargetRepo' } |
                Should -Throw '*TargetRepo*'
        }
    }

    Context 'Fail-loud: repo key missing from yamlRepos' {
        It 'throws when requested repo key is not present under yamlRepos' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'OtherRepo' = @{ baseBranch = 'develop' }
            } -Dir $testDir

            { & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'MissingRepo' } |
                Should -Throw "*'MissingRepo' not found under yamlRepos*"
        }

        It 'error message includes the missing repo name' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'SomeRepo' = @{ baseBranch = 'main' }
            } -Dir $testDir

            { & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'WantedRepo' } |
                Should -Throw '*WantedRepo*'
        }
    }

    Context 'Fail-loud: baseBranch empty or null' {
        It 'throws when baseBranch is an empty string' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'MyRepo' = @{ baseBranch = '' }
            } -Dir $testDir

            { & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'MyRepo' } |
                Should -Throw '*baseBranch is empty or missing*'
        }

        It 'throws when baseBranch key is absent from the repo entry' {
            $path = Join-Path $testDir 'pipeline-catalog.json'
            @{
                yamlRepos = @{
                    MyRepo = @{ someOtherKey = 'value' }
                }
            } | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8

            { & $script:ScriptPath -CatalogPath $path -RepoName 'MyRepo' } |
                Should -Throw '*baseBranch is empty or missing*'
        }

        It 'error message names the repo for context' {
            $catalogPath = Write-CatalogFile -YamlRepos @{
                'SpecificRepo' = @{ baseBranch = '' }
            } -Dir $testDir

            { & $script:ScriptPath -CatalogPath $catalogPath -RepoName 'SpecificRepo' } |
                Should -Throw '*SpecificRepo*'
        }
    }
}
