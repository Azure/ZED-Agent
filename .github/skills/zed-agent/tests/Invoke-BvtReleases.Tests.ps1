<#
.SYNOPSIS
    Pester tests for Invoke-BvtReleases.ps1 — the BVT steps (6/8/11) create the configured classic BVT
    releases (BCM 40785 + 47437, MABIsOfficial=true) right after the deployment and continue once
    all of their stages have finished, instead of waiting 24 h. vsrm is mocked with the shapes of
    BCM releases 17875754 / 17875780.
#>

BeforeAll {
    $script:S = Join-Path $PSScriptRoot '..\scripts\Invoke-BvtReleases.ps1'

    function New-Env([bool]$TestMode = $false) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $dir | Out-Null
        [ordered]@{ releaseId = '2026-11'; pipelineTriggerTimestamps = @{ step5 = '2026-11-16T05:08:39Z' }; steps = @() } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'state.json')
        @{ releaseId = '2026-11'; testMode = $TestMode } | ConvertTo-Json | Set-Content (Join-Path $dir 'release.json')
        @{ bvtReleases = @{ steps = @(6, 8, 11); timeoutHours = 12; releases = [ordered]@{
            'IaaSVM-CloudTest'     = @{ definitionId = 40785; variables = @{ MABIsOfficial = 'true' } }
            'IaaSVM-LHT-CloudTest' = @{ definitionId = 47437; variables = @{ MABIsOfficial = 'true' } } } } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'cat.json')
        @{ ado = @{ organization = 'msazure'; project = 'One' }; service = @{ displayName = 'BCM' } } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dir 'svc.json')
        return $dir
    }
    function Invoke-B([string]$Dir, [string]$Action, [int]$Step = 6, [hashtable]$Extra = @{}) {
        $splat = @{ Action = $Action; ReleaseId = '2026-11'; Step = $Step; StateFile = (Join-Path $Dir 'state.json'); StateLock = (Join-Path $Dir 'l'); AuditFile = (Join-Path $Dir 'a.jsonl'); ReleaseFile = (Join-Path $Dir 'release.json'); PipelineCatalogPath = (Join-Path $Dir 'cat.json'); ServiceConfigPath = (Join-Path $Dir 'svc.json'); AccessToken = 'tok' }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $script:S @splat
    }
    function Get-StepState([string]$Dir, [int]$Step = 6) { (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json).bvtReleases."$Step" }

    function Mock-Create {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/release/artifacts/versions\?releaseDefinitionId=\d+' } -MockWith {
            [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'Build'; defaultVersion = [pscustomobject]@{ id = 'c92196bc-c17c-45c6-b076-5f50c394c7b8'; name = '3.0.200.1760 (git_mgmt_recoverysvcs_test_develop)' } }) }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -match '/release/releases\?' } -MockWith {
            $b = $Body | ConvertFrom-Json
            $id = if ($b.definitionId -eq 40785) { 17880001 } else { 17880002 }
            [pscustomobject]@{ id = $id; name = "Release-$id"; status = 'active'; releaseDefinition = [pscustomobject]@{ name = $(if ($b.definitionId -eq 40785) { 'IaaSVM-CloudTest-Scheduled-Canary' } else { 'IaaSVM-LHT-CloudTest-Canary' }) }; _links = [pscustomobject]@{ web = [pscustomobject]@{ href = "https://msazure.visualstudio.com/One/_release?releaseId=$id" } } }
        }
    }
    # $Envs: ordered @{ stageName = status }
    function Mock-Release([long]$Id, [System.Collections.Specialized.OrderedDictionary]$Envs, [string]$RelStatus = 'active') {
        $global:BvRel = if ($global:BvRel) { $global:BvRel } else { @{} }
        $rank = 0
        $global:BvRel["$Id"] = [pscustomobject]@{ id = $Id; status = $RelStatus; releaseDefinition = [pscustomobject]@{ name = "def-$Id" }; environments = @($Envs.Keys | ForEach-Object { $rank++; [pscustomobject]@{ name = $_; status = $Envs[$_]; rank = $rank } }) }
    }
    function New-Envs([string]$Drop = 'partiallySucceeded', [string]$Ecy = 'inProgress', [string]$Ccy = 'inProgress', [string]$Ea = 'inProgress') {
        $o = [ordered]@{}; $o['Publish VSO Drop'] = $Drop; $o['IaaSVME2ETestsECY'] = $Ecy; $o['IaaSVME2ETestsCCY'] = $Ccy; $o['IaaSVME2ETestsEaCan'] = $Ea; return $o
    }
}

AfterAll { Remove-Variable -Name BvRel -Scope Global -ErrorAction SilentlyContinue }

Describe 'Invoke-BvtReleases' {
    BeforeEach {
        $global:BvRel = @{}
        Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' -and $Uri -match '/release/releases/(\d+)\?' } -MockWith {
            $null = $Uri -match '/release/releases/(\d+)\?'; $global:BvRel[$Matches[1]]
        }
    }

    It 'creates both releases with the latest artifact version and MABIsOfficial=true, once' {
        Mock-Create
        $d = New-Env
        $r = Invoke-B $d 'Start'
        $r.Success | Should -BeTrue
        $r.Phase | Should -Be 'running'
        @($r.Runs).Count | Should -Be 2
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $b = $Body | ConvertFrom-Json
            $b.definitionId -eq 40785 -and $b.isDraft -eq $false -and $b.variables.MABIsOfficial.value -eq 'true' -and
            @($b.variables.PSObject.Properties).Count -eq 1 -and
            $b.artifacts[0].alias -eq 'Build' -and $b.artifacts[0].instanceReference.id -eq 'c92196bc-c17c-45c6-b076-5f50c394c7b8' -and
            $b.description -match 'BCM release 2026-11 — Step 6 BVT'
        }
        $s = Get-StepState $d
        $s.status | Should -Be 'running'
        $s.runs.'IaaSVM-CloudTest'.releaseId | Should -Be 17880001
        $s.runs.'IaaSVM-LHT-CloudTest'.url | Should -Match 'releaseId=17880002'
        (Get-Content (Join-Path $d 'state.json') -Raw) | Should -Match '"step5": "2026-11-16T05:08:39Z"'

        $null = Invoke-B $d 'Start'   # re-entry: no duplicates
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'keeps running until every stage of both releases is final, then completes' {
        Mock-Create
        $d = New-Env
        $null = Invoke-B $d 'Start'
        Mock-Release 17880001 (New-Envs -Ecy 'partiallySucceeded' -Ccy 'partiallySucceeded' -Ea 'inProgress')
        Mock-Release 17880002 (New-Envs -Ecy 'succeeded' -Ccy 'succeeded' -Ea 'succeeded')
        $r = Invoke-B $d 'Poll'
        $r.Phase | Should -Be 'running'
        (Get-StepState $d).runs.'IaaSVM-LHT-CloudTest'.status | Should -Be 'completed'

        Mock-Release 17880001 (New-Envs -Ecy 'partiallySucceeded' -Ccy 'partiallySucceeded' -Ea 'partiallySucceeded')
        $r = Invoke-B $d 'Poll'
        $r.Phase | Should -Be 'completed'
        $r.Success | Should -BeTrue
        ($r.Runs | Where-Object key -eq 'IaaSVM-CloudTest').outcome | Should -Be 'partiallySucceeded'
        ($r.Runs | Where-Object key -eq 'IaaSVM-LHT-CloudTest').outcome | Should -Be 'partiallySucceeded'   # Publish VSO Drop is always partial
        $r.Summary | Should -Match '\| \[IaaSVM-CloudTest-Scheduled-Canary Release-17880001\]\(https://msazure.visualstudio.com/One/_release\?releaseId=17880001\) \| partiallySucceeded \|'
        (Get-StepState $d).completedAt | Should -Not -BeNullOrEmpty
    }

    It 'treats a rejected stage with later stages never starting as finished (outcome rejected)' {
        Mock-Create
        $d = New-Env
        $null = Invoke-B $d 'Start'
        Mock-Release 17880001 (New-Envs -Drop 'rejected' -Ecy 'notStarted' -Ccy 'notStarted' -Ea 'notStarted')
        Mock-Release 17880002 (New-Envs -Ecy 'succeeded' -Ccy 'succeeded' -Ea 'succeeded')
        $r = Invoke-B $d 'Poll'
        $r.Phase | Should -Be 'completed'
        ($r.Runs | Where-Object key -eq 'IaaSVM-CloudTest').outcome | Should -Be 'rejected'
    }

    It 'reports a release that could not be created, and -Rerun re-creates only that one' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/release/artifacts/versions\?releaseDefinitionId=40785' } -MockWith { [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'Build'; errorMessage = 'No versions found' }) } }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/release/artifacts/versions\?releaseDefinitionId=47437' } -MockWith { [pscustomobject]@{ artifactVersions = @([pscustomobject]@{ alias = 'Build'; defaultVersion = [pscustomobject]@{ id = 'v1'; name = 'n1' } }) } }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 17880002; name = 'Release-17880002'; status = 'active' } }
        $d = New-Env
        $r = Invoke-B $d 'Start'
        $r.Phase | Should -Be 'failed'
        $r.Success | Should -BeFalse
        ($r.Runs | Where-Object key -eq 'IaaSVM-CloudTest').error | Should -Match 'No versions found'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }

        Mock-Create
        $r2 = Invoke-B $d 'Start' -Extra @{ Rerun = $true }
        $r2.Phase | Should -Be 'running'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }   # only 40785 re-created
        $s = Get-StepState $d
        @($s.history).Count | Should -Be 1
        $s.history[0].status | Should -Be 'failed-to-start'
        $s.runs.'IaaSVM-CloudTest'.releaseId | Should -Be 17880001
        $s.runs.'IaaSVM-LHT-CloudTest'.releaseId | Should -Be 17880002
    }

    It 'times out after timeoutHours' {
        Mock-Create
        $d = New-Env
        $null = Invoke-B $d 'Start' -Extra @{ Now = [datetime]'2026-11-16T06:00:00Z' }
        Mock-Release 17880001 (New-Envs)
        Mock-Release 17880002 (New-Envs)
        (Invoke-B $d 'Poll' -Extra @{ Now = [datetime]'2026-11-16T12:00:00Z' }).Phase | Should -Be 'running'
        (Invoke-B $d 'Poll' -Extra @{ Now = [datetime]'2026-11-16T18:30:00Z' }).Phase | Should -Be 'timed-out'
    }

    It 'creates nothing in test mode and for steps that are not configured' {
        Mock Invoke-RestMethod { throw 'no API calls' }
        $d = New-Env -TestMode $true
        (Invoke-B $d 'Start').Phase | Should -Be 'skipped'
        $d2 = New-Env
        $r = Invoke-B $d2 'Start' -Step 7
        $r.Success | Should -BeFalse
        $r.Error | Should -Match 'no bvtReleases for Step 7'
    }

    It 'uses separate state per BVT step' {
        Mock-Create
        $d = New-Env
        $null = Invoke-B $d 'Start' -Step 6
        $null = Invoke-B $d 'Start' -Step 8
        Should -Invoke Invoke-RestMethod -Times 4 -Exactly -ParameterFilter { $Method -eq 'POST' }
        (Get-StepState $d 8).status | Should -Be 'running'
    }
}

Describe 'BVT releases wiring' {
    It 'watcher polls poll-bvt-releases via the script; cold resume knows the directive' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match "elseif \(\`$dir\.action -eq 'poll-bvt-releases'\)"
        $w | Should -Match 'Invoke-BvtReleases\.ps1.\) -Action Poll'
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match "'poll-bvt-releases' \{"
    }
}
