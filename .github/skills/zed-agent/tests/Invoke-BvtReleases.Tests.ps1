<#
.SYNOPSIS
    Pester tests for Invoke-BvtReleases.ps1 — the BVT steps (6/8/11) create the configured classic BVT
    releases (BCM 40785 + 47437, MABIsOfficial="True") right after the deployment and continue once
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
            'IaaSVM-CloudTest'     = @{ definitionId = 40785; variables = @{ MABIsOfficial = 'True' } }
            'IaaSVM-LHT-CloudTest' = @{ definitionId = 47437; variables = @{ MABIsOfficial = 'True' } } } } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'cat.json')
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
        $global:BvRel["$Id"] = [pscustomobject]@{ id = $Id; status = $RelStatus; variables = @{ MABIsOfficial = @{ value = 'True' } }; releaseDefinition = [pscustomobject]@{ name = "def-$Id" }; environments = @($Envs.Keys | ForEach-Object { $rank++; [pscustomobject]@{ name = $_; status = $Envs[$_]; rank = $rank } }) }
    }
    function New-Envs([string]$Drop = 'partiallySucceeded', [string]$Ecy = 'inProgress', [string]$Ccy = 'inProgress', [string]$Ea = 'inProgress') {
        $o = [ordered]@{}; $o['Publish VSO Drop'] = $Drop; $o['IaaSVME2ETestsECY'] = $Ecy; $o['IaaSVME2ETestsCCY'] = $Ccy; $o['IaaSVME2ETestsEaCan'] = $Ea; return $o
    }

    # Seed owner-verified existing runs directly: no Start/POST and no invented creation provenance.
    function New-VerifiedBvtState([string]$Dir, [string]$Creation = 'absent', [bool]$Cached = $true) {
        $st = Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json
        $runs = @{}
        foreach ($id in @(17880001, 17880002)) {
            Mock-Release $id (New-Envs -Ecy succeeded -Ccy succeeded -Ea succeeded)
            $rows = @()
            foreach ($env in $global:BvRel["$id"].environments) {
                $env | Add-Member -NotePropertyName id -NotePropertyValue (100 + $env.rank)
                if ($env.rank -eq 1) { continue } # Publish Drop does not consume the official variable.
                $phaseId = 600 + $env.rank
                $taskId = 700 + $env.rank
                $taskName = "CloudTest-$($env.rank)"
                $env | Add-Member -NotePropertyName deployPhasesSnapshot -NotePropertyValue @(
                    [pscustomobject]@{ workflowTasks = @([pscustomobject]@{
                        inputs = [pscustomobject]@{ parserProperties = 'other:value;worker:MABIsOfficialRun=$(MABIsOfficial);tail:value' }
                    }) }
                )
                # Deliberately unsorted: the highest attempt, not array position, is authoritative.
                $env | Add-Member -NotePropertyName deploySteps -NotePropertyValue @(
                    [pscustomobject]@{ attempt = 1; id = (400 + $env.rank); releaseDeployPhases = @() }
                    [pscustomobject]@{ attempt = 2; id = (500 + $env.rank); releaseDeployPhases = @(
                        [pscustomobject]@{ id = $phaseId; deploymentJobs = @(
                            [pscustomobject]@{ tasks = @([pscustomobject]@{ id = $taskId; name = $taskName }) }
                        ) }
                    ) }
                )
                $rows += @{ environmentId = $env.id; attempt = 2; deploymentId = (500 + $env.rank)
                    phaseId = $phaseId; taskId = $taskId; taskName = $taskName; line = 2 }
            }
            $key = if ($id -eq 17880001) { 'IaaSVM-CloudTest' } else { 'IaaSVM-LHT-CloudTest' }
            $runs[$key] = @{ releaseId = $id; name = "Release-$id"
                status = $(if ($Cached) { 'completed' } else { 'running' })
                outcome = $(if ($Cached) { 'partiallySucceeded' } else { $null })
                verifiedAttempts = @{ releaseId = $id; MABIsOfficial = 'True'; environments = $rows } }
            if ($Creation -ne 'absent') {
                $runs[$key].creationVariables = @{ MABIsOfficial = $(if ($Creation -eq 'boolean') { $true } else { 'true' }); other = 'unchanged' }
            }
        }
        $st | Add-Member -NotePropertyName bvtReleases -NotePropertyValue @{
            '6' = @{ status = $(if ($Cached) { 'completed' } else { 'running' })
                startedAt = '2026-11-16T06:00:00Z'; runs = $runs; history = @() }
        }
        $st | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $Dir 'state.json')
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

    It 'creates both releases with the latest artifact version and exact string MABIsOfficial="True", once' {
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
            $b.definitionId -eq 40785 -and $b.isDraft -eq $false -and
            $b.variables.MABIsOfficial.value -is [string] -and $b.variables.MABIsOfficial.value -ceq 'True' -and
            @($b.variables.PSObject.Properties).Count -eq 1 -and
            $b.artifacts[0].alias -eq 'Build' -and $b.artifacts[0].instanceReference.id -eq 'c92196bc-c17c-45c6-b076-5f50c394c7b8' -and
            $b.description -match 'BCM release 2026-11 — Step 6 BVT'
        }
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
            if ($Method -ne 'POST') { return $false }
            $v = ($Body | ConvertFrom-Json).variables.MABIsOfficial.value
            $v -is [string] -and $v -ceq 'True'
        }
        $s = Get-StepState $d
        $s.status | Should -Be 'running'
        $s.runs.'IaaSVM-CloudTest'.releaseId | Should -Be 17880001
        $s.runs.'IaaSVM-LHT-CloudTest'.url | Should -Match 'releaseId=17880002'
        $s.runs.'IaaSVM-CloudTest'.creationVariables.MABIsOfficial | Should -BeExactly 'True'
        (Get-Content (Join-Path $d 'state.json') -Raw) | Should -Match '"step5": "2026-11-16T05:08:39Z"'

        $null = Invoke-B $d 'Start'   # re-entry: no duplicates
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects invalid configured official values before any release POST: <Value>' -ForEach @(
        @{ Value = 'true' }, @{ Value = $true }, @{ Value = 'TRUE' }, @{ Value = 'False' }
    ) {
        Mock-Create
        $d = New-Env
        $cat = Get-Content (Join-Path $d 'cat.json') -Raw | ConvertFrom-Json
        foreach ($p in $cat.bvtReleases.releases.PSObject.Properties) { $p.Value.variables.MABIsOfficial = $Value }
        $cat | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $d 'cat.json')
        $r = Invoke-B $d 'Start'
        $r.Phase | Should -Be 'failed'
        $r.Success | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'does not accept legacy cached completion without immutable creation variables' {
        Mock-Create
        $d = New-Env
        $null = Invoke-B $d 'Start'
        $st = Get-Content (Join-Path $d 'state.json') -Raw | ConvertFrom-Json
        $st.bvtReleases.'6'.status = 'completed'
        foreach ($p in $st.bvtReleases.'6'.runs.PSObject.Properties) {
            $p.Value.status = 'completed'
            $p.Value.PSObject.Properties.Remove('creationVariables')
        }
        $st | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $d 'state.json')
        (Invoke-B $d 'Get').Phase | Should -Be 'failed'
        (Invoke-B $d 'Poll').Phase | Should -Be 'failed'
    }

    It 'blocks changed live official values even when all stages succeeded' {
        Mock-Create
        $d = New-Env
        $null = Invoke-B $d 'Start'
        Mock-Release 17880001 (New-Envs -Ecy succeeded -Ccy succeeded -Ea succeeded)
        Mock-Release 17880002 (New-Envs -Ecy succeeded -Ccy succeeded -Ea succeeded)
        $global:BvRel['17880002'].variables.MABIsOfficial.value = 'true'
        $r = Invoke-B $d 'Poll'
        $r.Phase | Should -Be 'failed'
        (Get-StepState $d).runs.'IaaSVM-LHT-CloudTest'.status | Should -Be 'invalid-evidence'
        # A later live edit cannot unquarantine already-consumed evidence.
        $global:BvRel['17880002'].variables.MABIsOfficial.value = 'True'
        (Invoke-B $d 'Poll').Phase | Should -Be 'failed'
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

Describe 'Invoke-BvtReleases verified attempt evidence' {
    BeforeEach {
        $global:BvRel = @{}
        # Catch-all mocks ensure an unexpected endpoint or write can never reach live ADO.
        Mock Invoke-RestMethod { throw "Unexpected REST call: $Method $Uri" }
        Mock Invoke-RestMethod -ParameterFilter {
            $Method -ne 'POST' -and $Uri -match '^https://vsrm\.dev\.azure\.com/msazure/One/_apis/release/releases/(17880001|17880002)\?api-version=7\.1$'
        } -MockWith {
            $null = $Uri -match '/releases/(\d+)\?'
            $global:BvRel[$Matches[1]]
        }
        Mock Invoke-WebRequest { throw "Unexpected log call: $Uri" }
        Mock Invoke-WebRequest -ParameterFilter {
            $Method -ne 'POST' -and $Uri -match '^https://vsrm\.dev\.azure\.com/msazure/One/_apis/release/releases/(17880001|17880002)/environments/10[234]/deployPhases/60[234]/tasks/70[234]/logs$'
        } -MockWith {
            [pscustomobject]@{ Content = "header`r`n2026-11-16T06:01:00Z worker:MABIsOfficialRun=True;other:value`r`nfooter" }
        }
    }

    AfterEach {
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -in @('PATCH', 'PUT', 'DELETE') }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -in @('PATCH', 'PUT', 'DELETE') }
    }

    It '<Action> accepts verified existing attempts with <Creation> creationVariables (cached=<Cached>) without rewriting provenance' -ForEach @(
        foreach ($action in @('Get', 'Poll')) {
            foreach ($creation in @('absent', 'lowercase', 'boolean')) {
                foreach ($cached in @($false, $true)) {
                    @{ Action = $action; Creation = $creation; Cached = $cached }
                }
            }
        }
    ) {
        $d = New-Env
        New-VerifiedBvtState $d -Creation $Creation -Cached $Cached
        $before = Get-StepState $d
        $r = Invoke-B $d $Action -Extra @{ Now = [datetime]'2026-11-16T07:00:00Z' }
        $expected = if ($Cached -or $Action -eq 'Poll') { 'completed' } else { 'running' }
        $r.Success | Should -BeTrue
        $r.Phase | Should -Be $expected
        @($r.Runs).Count | Should -Be 2
        foreach ($run in $r.Runs) {
            $run.status | Should -Be $expected
            $run.releaseId | Should -BeIn @(17880001, 17880002)
        }
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -match '/releases/17880001\?' }
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -match '/releases/17880002\?' }
        foreach ($id in @(17880001, 17880002)) {
            foreach ($rank in @(2, 3, 4)) {
                $url = "https://vsrm.dev.azure.com/msazure/One/_apis/release/releases/$id/environments/$(100 + $rank)/deployPhases/$(600 + $rank)/tasks/$(700 + $rank)/logs"
                Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Uri -eq $url }
            }
        }
        $after = Get-StepState $d
        foreach ($key in @('IaaSVM-CloudTest', 'IaaSVM-LHT-CloudTest')) {
            ($after.runs.$key.verifiedAttempts | ConvertTo-Json -Depth 10 -Compress) |
                Should -BeExactly ($before.runs.$key.verifiedAttempts | ConvertTo-Json -Depth 10 -Compress)
            if ($Creation -eq 'absent') {
                @($after.runs.$key.PSObject.Properties.Name) | Should -Not -Contain 'creationVariables'
            } else {
                ($after.runs.$key.creationVariables | ConvertTo-Json -Compress) |
                    Should -BeExactly ($before.runs.$key.creationVariables | ConvertTo-Json -Compress)
            }
        }
    }

    It 'Poll with verified attempts still waits for every regional environment in both releases' {
        $d = New-Env
        New-VerifiedBvtState $d -Cached $false
        $global:BvRel['17880001'].environments[3].status = 'inProgress'
        $r = Invoke-B $d 'Poll' -Extra @{ Now = [datetime]'2026-11-16T07:00:00Z' }
        $r.Success | Should -BeTrue
        $r.Phase | Should -Be 'running'
        (Get-StepState $d).runs.'IaaSVM-CloudTest'.status | Should -Be 'running'
        (Get-StepState $d).runs.'IaaSVM-LHT-CloudTest'.status | Should -Be 'completed'
        $global:BvRel['17880001'].environments[3].status = 'succeeded'
        $r = Invoke-B $d 'Poll' -Extra @{ Now = [datetime]'2026-11-16T07:01:00Z' }
        $r.Phase | Should -Be 'completed'
        $r.Success | Should -BeTrue
        ($r.Runs | Where-Object key -eq 'IaaSVM-CloudTest').outcome | Should -Be 'partiallySucceeded'
        (Get-StepState $d).completedAt | Should -Not -BeNullOrEmpty
    }

    It '<Action> accepts exact standalone mapping and log evidence at <Position>' -ForEach @(
        foreach ($action in @('Get', 'Poll')) {
            foreach ($position in @('first line', 'last line', 'quoted command argument')) {
                @{ Action = $action; Position = $position }
            }
        }
    ) {
        $d = New-Env
        New-VerifiedBvtState $d
        $st = Get-Content (Join-Path $d 'state.json') -Raw | ConvertFrom-Json
        foreach ($run in $st.bvtReleases.'6'.runs.PSObject.Properties.Value) {
            foreach ($row in $run.verifiedAttempts.environments) {
                $row.line = if ($Position -eq 'first line') { 1 } else { 2 }
            }
        }
        foreach ($rel in $global:BvRel.Values) {
            foreach ($env in $rel.environments | Select-Object -Skip 1) {
                $env.deployPhasesSnapshot[0].workflowTasks[0].inputs.parserProperties = 'worker:MABIsOfficialRun=$(MABIsOfficial)'
            }
        }
        if ($Position -eq 'first line') {
            Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/tasks/\d+/logs$' } -MockWith {
                [pscustomobject]@{ Content = "worker:MABIsOfficialRun=True`nfooter" }
            }
        } elseif ($Position -eq 'quoted command argument') {
            Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/tasks/\d+/logs$' } -MockWith {
                [pscustomobject]@{ Content = "header`ncommand -props `"worker:MABIsOfficialRun=True;worker:AzureEnvironment=Canary`"" }
            }
        } else {
            Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/tasks/\d+/logs$' } -MockWith {
                [pscustomobject]@{ Content = "header`nworker:MABIsOfficialRun=True" }
            }
        }
        $st | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $d 'state.json')
        $r = Invoke-B $d $Action
        $r.Success | Should -BeTrue
        $r.Phase | Should -Be 'completed'
        @($r.Runs | Where-Object status -eq 'completed').Count | Should -Be 2
        # Poll validates both while refreshing runs and again on the common output path.
        $logReads = if ($Action -eq 'Poll') { 12 } else { 6 }
        Should -Invoke Invoke-WebRequest -Times $logReads -Exactly
        @((Get-StepState $d).runs.'IaaSVM-CloudTest'.PSObject.Properties.Name) | Should -Not -Contain 'creationVariables'
    }

    It '<Action> fails closed for <Fault>, even with cached completion and valid creationVariables' -ForEach @(
        foreach ($action in @('Get', 'Poll')) {
            foreach ($fault in @(
                'proof release', 'proof lowercase', 'proof boolean', 'live lowercase',
                'missing environment', 'duplicate environment', 'extra environment',
                'newer retry', 'attempt number', 'deployment id', 'missing deployment',
                'phase id', 'duplicate phase', 'task id', 'duplicate task', 'task name',
                'mapping lowercase', 'mapping substring', 'mapping suffix', 'mapping duplicate', 'mapping absent',
                'line zero', 'line beyond log', 'wrong stored line',
                'lowercase log', 'empty log value', 'missing log value', 'duplicate log value',
                'unavailable log'
            )) { @{ Action = $action; Fault = $fault } }
        }
    ) {
        $d = New-Env
        New-VerifiedBvtState $d
        $st = Get-Content (Join-Path $d 'state.json') -Raw | ConvertFrom-Json
        $run = $st.bvtReleases.'6'.runs.'IaaSVM-CloudTest'
        # A valid creation record must not bypass an invalid, preferred verifiedAttempts record.
        $run | Add-Member -NotePropertyName creationVariables -NotePropertyValue @{ MABIsOfficial = 'True' }
        $proof = $run.verifiedAttempts
        $row = $proof.environments[0]
        $env = $global:BvRel['17880001'].environments[1]
        switch ($Fault) {
            'proof release' { $proof.releaseId = 17889999 }
            'proof lowercase' { $proof.MABIsOfficial = 'true' }
            'proof boolean' { $proof.MABIsOfficial = $true }
            'live lowercase' { $global:BvRel['17880001'].variables.MABIsOfficial.value = 'true' }
            'missing environment' { $proof.environments = @($proof.environments | Select-Object -Skip 1) }
            'duplicate environment' { $proof.environments = @($proof.environments) + @($row) }
            'extra environment' {
                $proof.environments = @($proof.environments) + @([pscustomobject]@{ environmentId = 999 })
            }
            'newer retry' {
                $env.deploySteps = @($env.deploySteps) + @([pscustomobject]@{ attempt = 3; id = 999; releaseDeployPhases = @() })
            }
            'attempt number' { $row.attempt = 1 }
            'deployment id' { $row.deploymentId = 999 }
            'missing deployment' { $env.deploySteps = @() }
            'phase id' { $row.phaseId = 999 }
            'duplicate phase' {
                $env.deploySteps[1].releaseDeployPhases = @($env.deploySteps[1].releaseDeployPhases) * 2
            }
            'task id' { $row.taskId = 999 }
            'duplicate task' {
                $job = $env.deploySteps[1].releaseDeployPhases[0].deploymentJobs[0]
                $job.tasks = @($job.tasks) * 2
            }
            'task name' { $row.taskName = $row.taskName.ToLowerInvariant() }
            'mapping lowercase' {
                $env.deployPhasesSnapshot[0].workflowTasks[0].inputs.parserProperties = 'worker:MABIsOfficialRun=$(mabisofficial)'
            }
            'mapping substring' {
                $env.deployPhasesSnapshot[0].workflowTasks[0].inputs.parserProperties = 'notworker:MABIsOfficialRun=$(MABIsOfficial)'
            }
            'mapping suffix' {
                $env.deployPhasesSnapshot[0].workflowTasks[0].inputs.parserProperties = 'worker:MABIsOfficialRun=$(MABIsOfficial)extra'
            }
            'mapping duplicate' {
                $env.deployPhasesSnapshot[0].workflowTasks = @($env.deployPhasesSnapshot[0].workflowTasks) * 2
            }
            'mapping absent' {
                foreach ($e in $global:BvRel['17880001'].environments | Select-Object -Skip 1) {
                    $e.deployPhasesSnapshot[0].workflowTasks[0].inputs.parserProperties = 'other:value'
                }
            }
            'line zero' { $row.line = 0 }
            'line beyond log' { $row.line = 99 }
            'wrong stored line' { $row.line = 1 } # Exact True exists, but only on line 2.
            'lowercase log' {
                Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/releases/17880001/environments/' } -MockWith {
                    [pscustomobject]@{ Content = "header`nworker:MABIsOfficialRun=true`nfooter" }
                }
            }
            'empty log value' {
                Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/releases/17880001/environments/' } -MockWith {
                    [pscustomobject]@{ Content = "header`nworker:MABIsOfficialRun=;other:value`nfooter" }
                }
            }
            'missing log value' {
                Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/releases/17880001/environments/' } -MockWith {
                    [pscustomobject]@{ Content = "header`nnotworker:MABIsOfficialRun=True`nfooter" }
                }
            }
            'duplicate log value' {
                Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/releases/17880001/environments/' } -MockWith {
                    [pscustomobject]@{ Content = "header`nworker:MABIsOfficialRun=True;worker:MABIsOfficialRun=True`nfooter" }
                }
            }
            'unavailable log' {
                Mock Invoke-WebRequest -ParameterFilter { $Uri -match '/releases/17880001/environments/' } -MockWith {
                    throw 'Task log unavailable'
                }
            }
        }
        $st | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $d 'state.json')
        $r = Invoke-B $d $Action
        $r.Success | Should -BeFalse
        $r.Phase | Should -Be 'failed'
        $bad = $r.Runs | Where-Object key -eq 'IaaSVM-CloudTest'
        $bad.status | Should -Be 'invalid-evidence'
        $bad.error | Should -Match '^BVT_VARIABLE_EVIDENCE_INVALID:'
        ($r.Runs | Where-Object key -eq 'IaaSVM-LHT-CloudTest').status | Should -Be 'completed'
        $events = @(Get-Content (Join-Path $d 'a.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object {
            $_.event -eq 'bvt-evidence-invalid' -and $_.key -eq 'IaaSVM-CloudTest' -and $_.releaseId -eq 17880001
        }).Count | Should -BeGreaterThan 0
        if ($Action -eq 'Poll') {
            (Get-StepState $d).status | Should -Be 'failed'
            (Get-StepState $d).runs.'IaaSVM-CloudTest'.status | Should -Be 'invalid-evidence'
        } else {
            # Get is read-only: quarantine is returned, not silently written into persisted runs.
            (Get-StepState $d).runs.'IaaSVM-CloudTest'.status | Should -Be 'completed'
        }
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
