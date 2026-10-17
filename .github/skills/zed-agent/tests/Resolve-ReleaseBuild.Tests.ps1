<#
.SYNOPSIS
    Pester tests for Resolve-ReleaseBuild.ps1 (ado.releaseMode = "deploy-base": previous release from
    production run history, deploy commit + CI build reuse, build pinning) and the deploy-base config
    validation. ADO is mocked; the commit walk uses a temp git repo.
    (Also verified live on BCM: previous release = build 185093141 / master@f7a8c1eab from prod run
    185113899; deploy commit 6e321754f reused CI build 186140297; pins resolve for BCM-CANARY,
    BCM-EACAN and BCM-PROD; ADO preview accepted a pinned BCM-PROD request.)
#>

BeforeAll {
    $script:S = Join-Path $PSScriptRoot '..\scripts\Resolve-ReleaseBuild.ps1'

    function New-Cfg {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $dir | Out-Null
        @{ ado = @{ organization = 'msazure'; project = 'One'; repository = 'r'; baseBranch = 'master'; releaseMode = 'deploy-base' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'service-config.json')
        [ordered]@{
            officialBuild = @{ id = 223537; templateParameters = @{ debug = 'False' } }
            artifactFeed  = @{ type = 'CloudVaultArtifacts-v3'; connectionId = 'conn'; connectionName = 'CloudVault'; sourceId = 'src'; feedBranchPrefix = 'Mgmt_RecoverySvcs_IaaSCoord_'; buildDefinitionId = 223537 }
            canary        = [ordered]@{ 'BCM-CANARY' = @{ id = 391437; buildResource = 'bcm_service' }; 'BCM-EACAN' = @{ id = 391732; buildResource = 'bcm_develop' } }
            production    = [ordered]@{ 'BCM-PROD' = @{ id = 432616; buildResource = 'bcm_service' } }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'pipeline-catalog.json')
        return $dir
    }
    function Invoke-RRB([string]$Dir, [string]$Action, [hashtable]$Extra = @{}) {
        $splat = @{ Action = $Action; ServiceConfigPath = (Join-Path $Dir 'service-config.json'); PipelineCatalogPath = (Join-Path $Dir 'pipeline-catalog.json'); AccessToken = 'tok'; RepoPath = $Dir }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $script:S @splat
    }
    function Mock-Build([long]$Id, [string]$Number, [string]$Sha, [string]$Branch = 'master', [string]$Result = 'succeeded', [int]$Def = 223537) {
        if (-not $global:RrbBuilds) { $global:RrbBuilds = @{} }
        $global:RrbBuilds[$Id] = [pscustomobject]@{ id = $Id; buildNumber = $Number; sourceVersion = $Sha; sourceBranch = "refs/heads/$Branch"; status = 'completed'; result = $Result; definition = [pscustomobject]@{ id = $Def; name = "def$Def" } }
    }
}

AfterAll { Remove-Variable -Name RrbBuilds, RrbRuns, RrbFeed -Scope Global -ErrorAction SilentlyContinue }

Describe 'Resolve-ReleaseBuild' {
    BeforeEach {
        $global:RrbBuilds = @{}
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/build/builds/(\d+)\?' } -MockWith {
            $null = $Uri -match '/build/builds/(\d+)\?'; $b = $global:RrbBuilds[[long]$Matches[1]]
            if (-not $b) { throw '404' }; $b
        }
    }

    Context 'PreviousRelease' {
        It 'takes the newest real production rollout and its consumed build, skipping validate-only / canceled / failed runs' {
            Mock-Build 185093141 '3.0.883.0' ('f7a8c1eab' + '0' * 31)
            Mock-Build 183534030 '3.0.882.0' ('db4a2842b' + '0' * 31)
            $global:RrbRuns = @{
                100 = @{ queue = '2026-10-12T00:00:00Z'; result = 'canceled'; validate = 'true'; ver = '3_0_883_0_185093141 (x)' }
                101 = @{ queue = '2026-10-11T00:00:00Z'; result = $null; validate = 'true'; ver = '3_0_884_0_186104896 (x)' }
                102 = @{ queue = '2026-10-10T00:00:00Z'; result = $null; validate = 'False'; ver = '3_0_883_0_185093141 (x)' }
                103 = @{ queue = '2026-09-18T00:00:00Z'; result = 'failed'; validate = 'False'; ver = '3_0_881_0_181126563 (x)' }
                104 = @{ queue = '2026-09-30T00:00:00Z'; result = $null; validate = 'False'; ver = '3_0_882_0_183534030 (x)' }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*build/builds?definitions=432616*' } -MockWith {
                [pscustomobject]@{ value = @($global:RrbRuns.Keys | ForEach-Object { $r = $global:RrbRuns[$_]; [pscustomobject]@{ id = $_; queueTime = $r.queue; result = $r.result; status = $(if ($r.result) { 'completed' } else { 'inProgress' }) } }) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/pipelines/432616/runs/(\d+)' } -MockWith {
                $null = $Uri -match '/runs/(\d+)'; $r = $global:RrbRuns[[int]$Matches[1]]
                [pscustomobject]@{ templateParameters = [pscustomobject]@{ ValidateOnlyRollOut = $r.validate }; resources = [pscustomobject]@{ builds = [pscustomobject]@{ bcm_service = [pscustomobject]@{ versionName = $r.ver } } } }
            }
            $d = New-Cfg
            $r = Invoke-RRB $d 'PreviousRelease'
            $r.PreviousBuildId | Should -Be 185093141
            $r.PreviousBuildNumber | Should -Be '3.0.883.0'
            $r.PreviousCommit | Should -BeLike 'f7a8c1eab*'
            $r.PreviousBranch | Should -Be 'master'
            $r.ProdRunId | Should -Be 102
            @($r.Candidates.buildId) | Should -Be @(185093141, 183534030)
        }

        It 'requires buildResource on production pipelines' {
            $d = New-Cfg
            $c = Get-Content (Join-Path $d 'pipeline-catalog.json') -Raw | ConvertFrom-Json
            $c.production.'BCM-PROD'.PSObject.Properties.Remove('buildResource')
            $c | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $d 'pipeline-catalog.json')
            { Invoke-RRB $d 'PreviousRelease' } | Should -Throw '*buildResource is required*'
        }
    }

    Context 'DeployCommit / QueueBuild (temp git repo)' {
        BeforeAll {
            function New-Repo {
                $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
                $origin = Join-Path $root 'o.git'; $work = Join-Path $root 'w'
                New-Item -ItemType Directory $root | Out-Null
                foreach ($a in @(@('init', '-q', '--bare', '-b', 'master', $origin), @('clone', '-q', $origin, $work))) { & git -C $root @a 2>$null | Out-Null }
                foreach ($kv in @(@('user.email', 'z@x.com'), @('user.name', 'ZED'))) { & git -C $work config $kv[0] $kv[1] }
                & git -C $work checkout -q -b master 2>$null
                foreach ($m in 'Merged PR 1: feature', 'Incrementing build version to 3.0.1.0 ***NO_CI***', 'Merged PR 2: fix', 'Incrementing build version to 3.0.2.0 ***NO_CI***') {
                    & git -C $work commit -q --allow-empty -m $m
                }
                & git -C $work push -q origin master 2>$null
                return $work
            }
        }

        It 'picks the newest non-***NO_CI*** commit and reuses its CI build' {
            $w = New-Repo
            $sha = (& git -C $w rev-parse HEAD~1).Trim()
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*build/builds?definitions=223537*' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 9; buildNumber = '3.0.2.0'; sourceVersion = $sha; status = 'completed'; result = 'succeeded' }
                    [pscustomobject]@{ id = 8; buildNumber = '3.0.1.9'; sourceVersion = $sha; status = 'completed'; result = 'canceled' }) }
            }
            $d = New-Cfg
            $r = Invoke-RRB $d 'DeployCommit' @{ RepoPath = $w }
            $r.Commit | Should -Be $sha
            $r.Subject | Should -Be 'Merged PR 2: fix'
            $r.BuildId | Should -Be 9
        }

        It 'reports no build when CI has not built the commit; QueueBuild pins the commit' {
            $w = New-Repo
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*build/builds?definitions=223537*' } -MockWith { [pscustomobject]@{ value = @() } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/pipelines/223537/runs*' } -MockWith { [pscustomobject]@{ id = 77; name = '3.0.3.0' } }
            $d = New-Cfg
            $r = Invoke-RRB $d 'DeployCommit' @{ RepoPath = $w }
            $r.BuildId | Should -BeNullOrEmpty
            $q = Invoke-RRB $d 'QueueBuild' @{ RepoPath = $w; Commit = $r.Commit }
            $q.BuildId | Should -Be 77
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'POST' -or $Uri -notlike '*/pipelines/223537/runs*') { return $false }
                $b = $Body | ConvertFrom-Json
                $b.resources.repositories.self.refName -eq 'refs/heads/master' -and $b.resources.repositories.self.version -eq $r.Commit -and $b.templateParameters.debug -eq 'False'
            }
        }

        It 'QueueBuild refuses a short sha' {
            $d = New-Cfg
            { Invoke-RRB $d 'QueueBuild' @{ Commit = 'abc1234' } } | Should -Throw '*full 40-character sha*'
        }
    }

    Context 'ResolveBuild / PinResources' {
        It 'resolves a build link and rejects non-official builds and branch names' {
            Mock-Build 185093141 '3.0.883.0' ('f7a8c1eab' + '0' * 31)
            Mock-Build 42 'x' ('a' * 40) 'develop' 'succeeded' 999
            $d = New-Cfg
            $r = Invoke-RRB $d 'ResolveBuild' @{ Build = 'https://msazure.visualstudio.com/One/_build/results?buildId=185093141&view=results' }
            $r.BuildId | Should -Be 185093141
            $r.Branch | Should -Be 'master'
            { Invoke-RRB $d 'ResolveBuild' @{ Build = '42' } } | Should -Throw '*not the official build*'
            { Invoke-RRB $d 'ResolveBuild' @{ Build = 'master' } } | Should -Throw '*not a build link*'
        }

        It 'pins a build to its feed version for the pipeline''s build resource' {
            Mock-Build 186140297 '3.0.885.0' ('6e321754f' + '0' * 31)
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*vsrm*/Release/artifacts/versions*' } -MockWith {
                $src = @($Body | ConvertFrom-Json)[0]
                $global:RrbFeed = $src.definitionReference.branch.id
                [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = $src.alias; errorMessage = $null; versions = @(
                    [pscustomobject]@{ id = 'v-new'; name = '3_0_886_0_186200000 (x)' }
                    [pscustomobject]@{ id = 'v-rel'; name = '3_0_885_0_186140297 (Mgmt_RecoverySvcs_IaaSCoord_master)' }) }) }
            }
            $d = New-Cfg
            $r = Invoke-RRB $d 'PinResources' @{ BuildId = 186140297; PipelineKey = 'canary:BCM-EACAN' }
            $global:RrbFeed | Should -Be 'Mgmt_RecoverySvcs_IaaSCoord_master'
            $r.Alias | Should -Be 'bcm_develop'
            $r.VersionId | Should -Be 'v-rel'
            $r.Resources.builds.bcm_develop.version | Should -Be 'v-rel'
        }

        It 'refuses to pin a build that is not in the feed or did not succeed' {
            Mock-Build 5 '3.0.0.5' ('b' * 40)
            Mock-Build 6 '3.0.0.6' ('c' * 40) 'master' 'failed'
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*vsrm*' } -MockWith { [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'bcm_service'; errorMessage = $null; versions = @() }) } }
            $d = New-Cfg
            { Invoke-RRB $d 'PinResources' @{ BuildId = 5; PipelineKey = 'production:BCM-PROD' } } | Should -Throw '*not (yet) in artifact feed*'
            { Invoke-RRB $d 'PinResources' @{ BuildId = 6; PipelineKey = 'production:BCM-PROD' } } | Should -Throw '*only a successfully completed build*'
        }
    }
}

Describe 'deploy-base wiring' {
    BeforeAll {
        $script:Loader = Join-Path $PSScriptRoot '..\scripts\Load-ServiceConfig.ps1'
        function Write-Cfg([string]$Mode, [bool]$Feed = $true, [bool]$AllPinned = $true) {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $dir | Out-Null
            [ordered]@{
                service = @{ name = 'BCM'; displayName = 'BCM' }; serviceTreeIds = @{ safefly = 'x' }
                ado = @{ organization = 'o'; project = 'p'; repository = 'r'; branchPrefix = 'releases/bcm-'; baseBranch = 'master'; releaseMode = $Mode }
                kusto = @{ bvt = @{ cluster = 'c' }; canary = @{ cluster = 'c' } }; sharepoint = @{ sitePath = '/s' }
                notifications = @{ groups = @{ permanent = @('a@b.c') }; routing = @{} }; stepGates = @{ x = $false }
            } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'service-config.json')
            $cat = [ordered]@{ canary = [ordered]@{ A = @{ id = 1; buildResource = 'bcm_service' }; B = @{ id = 2 } }; production = [ordered]@{ P = @{ id = 3; buildResource = 'bcm_service' } } }
            if ($AllPinned) { $cat.canary.B.buildResource = 'bcm_develop' }
            if ($Feed) { $cat.artifactFeed = @{ connectionId = 'c'; sourceId = 's'; feedBranchPrefix = 'P_' } }
            $cat | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'pipeline-catalog.json')
            Join-Path $dir 'service-config.json'
        }
    }
    It 'accepts a complete deploy-base config and cut-branch configs' {
        { & $Loader -ServiceConfigPath (Write-Cfg 'deploy-base') } | Should -Not -Throw
        { & $Loader -ServiceConfigPath (Write-Cfg 'cut-branch' $false $false) } | Should -Not -Throw
    }
    It 'rejects deploy-base without artifactFeed' { { & $Loader -ServiceConfigPath (Write-Cfg 'deploy-base' $false) } | Should -Throw '*artifactFeed*' }
    It 'rejects deploy-base with an unpinned pipeline' { { & $Loader -ServiceConfigPath (Write-Cfg 'deploy-base' $true $false) } | Should -Throw '*missing: canary.B*' }
    It 'rejects an unknown mode' { { & $Loader -ServiceConfigPath (Write-Cfg 'trunk') } | Should -Throw '*not supported*' }

    It 'Invoke-TriggerAndCancel forwards pinned build resources' {
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-TriggerAndCancel.ps1') -Raw
        $c | Should -Match '\$BuildResources'
        $c | Should -Match '\$resourcesObj\.builds = \$BuildResources'
    }

    It 'Invoke-RevertBits prefers release.json previousCommit / currentCommit' {
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-RevertBits.ps1') -Raw
        $c | Should -Match "release\.PSObject\.Properties\['previousCommit'\]"
        $c | Should -Match "release\.PSObject\.Properties\['currentCommit'\]"
        $c | Should -Match "Release\.PSObject\.Properties\['releaseTag'\]"
    }
}
