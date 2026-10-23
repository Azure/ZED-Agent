<#
.SYNOPSIS
    Pester tests for Invoke-ScheduleGuard.ps1 (pause a canary pipeline's own scheduled
    deployments after ZED's Step 5 run succeeds; restore at Step 6 sign-off). ADO is mocked.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-ScheduleGuard.ps1'

    function New-Env {
        param([string]$Step5 = 'in-progress', [string]$Step6 = 'pending', [bool]$TestMode = $false, [object[]]$RunIds = @(5001, 5002), [object]$Guard = $null)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $steps = 1..16 | ForEach-Object { [ordered]@{ number = $_; name = "s$_"; status = 'pending' } }
        1..4 | ForEach-Object { $steps[$_ - 1].status = 'completed' }
        $steps[4].status = $Step5; $steps[5].status = $Step6
        [ordered]@{ releaseId = '2026-11'; steps = $steps; triggeredPipelines = @{ '5' = $RunIds } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'state.json') -Encoding UTF8
        [ordered]@{ releaseId = '2026-11'; currentBranch = 'releases/bcm-2611'; testMode = $TestMode } |
            ConvertTo-Json | Set-Content (Join-Path $dir 'release.json') -Encoding UTF8
        $sg = if ($Guard) { $Guard } else { [ordered]@{ variable = 'enableSchedule'; disabledValue = 'false'; enabledValue = 'true' } }
        [ordered]@{
            canary = [ordered]@{
                'BCM-CANARY' = [ordered]@{ name = 'c'; id = 391437; sourceBranch = 'x'; templateParameters = @{} }
                'BCM-EACAN'  = [ordered]@{ name = 'e'; id = 391732; sourceBranch = 'x'; templateParameters = @{}; scheduleGuard = $sg }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'pipeline-catalog.json') -Encoding UTF8
        return $dir
    }

    function Invoke-Guard {
        param([string]$Dir, [string]$Action, [hashtable]$Extra = @{})
        $splat = @{
            Action = $Action; ReleaseId = '2026-11'
            StateFile = (Join-Path $Dir 'state.json'); StateLock = (Join-Path $Dir 'state.json.lock')
            AuditFile = (Join-Path $Dir 'audit.jsonl'); ReleaseFile = (Join-Path $Dir 'release.json')
            PipelineCatalogPath = (Join-Path $Dir 'pipeline-catalog.json')
            Organization = 'msazure'; Project = 'One'; AccessToken = 'tok'
        }
        foreach ($k in $Extra.Keys) { $splat[$k] = $Extra[$k] }
        & $ScriptPath @splat
    }

    function Get-Guard([string]$Dir) { (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json).scheduleGuards.'BCM-EACAN' }
    function Set-Step([string]$Dir, [int]$N, [string]$Status) {
        $p = Join-Path $Dir 'state.json'
        $s = Get-Content $p -Raw | ConvertFrom-Json
        ($s.steps | Where-Object number -eq $N).status = $Status
        $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
    }

    # A realistic slice of a build definition, including a date that must round-trip as a string.
    function New-Definition([string]$Value) {
        $json = @"
{"id":391732,"revision":131,"name":"Mgmt-Recoverysvcs-IaasCoord-BCM-EaCan-Service-Deployment","createdDate":"2025-03-04T05:06:07.123Z",
 "variables":{"enableSchedule":{"value":"$Value"},"PipelineClassification_Audited":{"value":"Production"}},
 "triggers":[{"triggerType":"schedule","schedules":[]}],"tags":[],"process":{"type":2,"yamlFilename":"a.yml"}}
"@
        return [pscustomobject]@{ Content = $json }
    }
}

Describe 'Invoke-ScheduleGuard' {

    Context 'Disable after ZED''s Step 5 run succeeds' {
        It 'does nothing while the EA-CAN run is still running or another pipeline finished' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ id = 5001; definition = @{ id = 391437 }; status = 'completed'; result = 'succeeded' }
                    [pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'inProgress'; result = $null }
                ) }
            }
            Mock Invoke-WebRequest { throw 'must not read the definition yet' }
            $d = New-Env
            $r = Invoke-Guard $d 'Sync'
            $r.Success | Should -BeTrue
            @($r.Results).Count | Should -Be 0
            Get-Guard $d | Should -BeNullOrEmpty
        }

        It 'never disables after a failed or cancelled EA-CAN run' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'canceled' }) }
            }
            Mock Invoke-WebRequest { throw 'must not read the definition' }
            $d = New-Env
            @((Invoke-Guard $d 'Sync').Results).Count | Should -Be 0
        }

        It 'sets enableSchedule=false once the EA-CAN run succeeded, changing nothing else' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded' }) }
            }
            Mock Invoke-WebRequest { New-Definition 'true' }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 132 } }

            $d = New-Env
            $r = Invoke-Guard $d 'Sync'
            $r.Results[0].status | Should -Be 'disabled'
            $r.NotifyEvents | Should -Contain 'schedule-guard-disabled:BCM-EACAN'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'PUT') { return $false }
                $b = $Body | ConvertFrom-Json -AsHashtable -DateKind String
                $Uri -like '*/build/definitions/391732?*' -and
                $b.variables.enableSchedule.value -eq 'false' -and
                $b.variables.PipelineClassification_Audited.value -eq 'Production' -and
                $b.revision -eq 131 -and
                $b.createdDate -eq '2025-03-04T05:06:07.123Z' -and
                $b.triggers[0].triggerType -eq 'schedule'
            }
            $g = Get-Guard $d
            $g.status | Should -Be 'disabled'
            $g.originalValue | Should -Be 'true'
            $g.disabledByRunId | Should -Be 5002

            # Next tick: already disabled -> no API calls at all
            $r2 = Invoke-Guard $d 'Sync'
            @($r2.Results).Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'records preexisting when the variable was already false and never re-enables it' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded' }) }
            }
            Mock Invoke-WebRequest { New-Definition 'false' }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { throw 'no PUT expected' }
            $d = New-Env
            (Invoke-Guard $d 'Sync').Results[0].status | Should -Be 'preexisting'
            Set-Step $d 6 'completed'
            @((Invoke-Guard $d 'Sync').Results).Count | Should -Be 0
            (Get-Guard $d).status | Should -Be 'preexisting'
        }

        It 'is inert in test mode' {
            Mock Invoke-RestMethod { throw 'no API calls in test mode' }
            Mock Invoke-WebRequest { throw 'no API calls in test mode' }
            $d = New-Env -TestMode $true
            $r = Invoke-Guard $d 'Sync'
            $r.Success | Should -BeTrue
            @($r.Results).Count | Should -Be 0
        }
    }

    Context 'Restore at Step 6 sign-off' {
        BeforeEach {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded' }) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 140 } }
        }

        It 'Restore (approve-bvt) sets enableSchedule=true' {
            Mock Invoke-WebRequest { New-Definition 'true' }
            $d = New-Env
            $null = Invoke-Guard $d 'Sync'
            Mock Invoke-WebRequest { New-Definition 'false' }
            $r = Invoke-Guard $d 'Restore' @{ Reason = 'approve-bvt' }
            $r.Results[0].status | Should -Be 'restored'
            $r.NotifyEvents | Should -Contain 'schedule-guard-restored:BCM-EACAN'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                if ($Method -ne 'PUT') { return $false }
                ($Body | ConvertFrom-Json).variables.enableSchedule.value -eq 'true'
            }
            (Get-Guard $d).restoreReason | Should -Be 'approve-bvt'
        }

        It 'Sync restores as a safety net when Step 6 is <s6>' -ForEach @(@{ s6 = 'completed' }, @{ s6 = 'skipped' }) {
            Mock Invoke-WebRequest { New-Definition 'true' }
            $d = New-Env
            $null = Invoke-Guard $d 'Sync'
            Set-Step $d 6 $s6
            Mock Invoke-WebRequest { New-Definition 'false' }
            $r = Invoke-Guard $d 'Sync'
            $r.Results[0].status | Should -Be 'restored'
            (Get-Guard $d).restoreReason | Should -Be "step-6-$s6"
        }

        It 'does not overwrite a value someone already changed back' {
            Mock Invoke-WebRequest { New-Definition 'true' }
            $d = New-Env
            $null = Invoke-Guard $d 'Sync'
            # someone flipped it to 'true' manually; restore must not PUT
            $r = Invoke-Guard $d 'Restore'
            $r.Results[0].status | Should -Be 'restored'
            $r.Results[0].note | Should -Match 'changed outside ZED'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'Restore is a no-op when ZED never disabled anything' {
            Mock Invoke-WebRequest { throw 'must not read' }
            $d = New-Env
            @((Invoke-Guard $d 'Restore').Results).Count | Should -Be 0
        }
    }

    Context 'rebuild re-arm' {
        It 'restores, then re-disables only after the re-queued run succeeds' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded' }) }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 150 } }
            Mock Invoke-WebRequest { New-Definition 'true' }
            $d = New-Env -Step5 'completed'
            $null = Invoke-Guard $d 'Sync'
            (Get-Guard $d).status | Should -Be 'disabled'

            { Invoke-Guard $d 'Rearm' @{ PipelineKey = 'BCM-EACAN'; RunId = 6001 } } | Should -Throw '*Restore*'

            Mock Invoke-WebRequest { New-Definition 'false' }
            (Invoke-Guard $d 'Restore' @{ PipelineKey = 'BCM-EACAN'; Reason = 'rebuild' }).Results[0].status | Should -Be 'restored'
            (Invoke-Guard $d 'Rearm' @{ PipelineKey = 'BCM-EACAN'; RunId = 6001 }).Results[0].status | Should -Be 'armed'

            # old Step 5 run 5002 is succeeded, new run 6001 still running -> must NOT disable
            Mock Invoke-WebRequest { New-Definition 'true' }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/build/builds/6001?*' } -MockWith { [pscustomobject]@{ id = 6001; status = 'inProgress' } }
            @((Invoke-Guard $d 'Sync').Results).Count | Should -Be 0
            (Get-Guard $d).status | Should -Be 'armed'

            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/build/builds/6001?*' } -MockWith { [pscustomobject]@{ id = 6001; status = 'completed'; result = 'succeeded' } }
            $r = Invoke-Guard $d 'Sync'
            $r.Results[0].status | Should -Be 'disabled'
            (Get-Guard $d).disabledByRunId | Should -Be 6001
        }

        It 'Rearm is a no-op after Step 6 sign-off' {
            $d = New-Env -Step6 'completed'
            @((Invoke-Guard $d 'Rearm' @{ PipelineKey = 'BCM-EACAN'; RunId = 6001 }).Results).Count | Should -Be 0
        }
    }

    Context 'Failures' {
        It 'reports a failed disable once, retries on the next tick, and Sync never throws' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded' }) }
            }
            Mock Invoke-WebRequest { New-Definition 'true' }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { throw 'TF50309: insufficient permissions to edit the build pipeline' }
            $d = New-Env
            $r = Invoke-Guard $d 'Sync'
            $r.Success | Should -BeFalse
            $r.Results[0].status | Should -Be 'disable-failed'
            $r.NotifyEvents | Should -Contain 'schedule-guard-failed:BCM-EACAN'

            $r2 = Invoke-Guard $d 'Sync'
            $r2.Results[0].status | Should -Be 'disable-failed'
            $r2.NotifyEvents | Should -BeNullOrEmpty   # same error -> not re-notified

            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 133 } }
            (Invoke-Guard $d 'Sync').Results[0].status | Should -Be 'disabled'
        }

        It 'Restore reports restore-failed (Step 7 must halt) without throwing' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*builds?buildIds=*' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded' }) }
            }
            Mock Invoke-WebRequest { New-Definition 'true' }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 132 } }
            $d = New-Env
            $null = Invoke-Guard $d 'Sync'
            Mock Invoke-WebRequest { throw 'network down' }
            $r = Invoke-Guard $d 'Restore'
            $r.Success | Should -BeFalse
            $r.Results[0].status | Should -Be 'restore-failed'
            (Get-Guard $d).status | Should -Be 'restore-failed'
        }
    }
}

Describe 'Invoke-ScheduleGuard — schedule trigger mode + foreign-run cancel' {
    BeforeAll {
        $script:TrigGuard = [ordered]@{ pauseScheduleTriggers = $true; variable = 'enableSchedule'; disabledValue = 'false'; enabledValue = 'true'; cancelForeignRuns = $true }
        $script:Sched = '{"schedules":[{"branchFilters":["+refs/heads/develop"],"timeZoneId":"India Standard Time","startHours":23,"startMinutes":0,"daysToBuild":79,"scheduleJobId":"a5cebf79-6d73-488a-b95e-9afa0920a014","scheduleOnlyWithChanges":false}],"triggerType":"schedule"}'
        # Shape of the live EA-CAN definition (391732 rev 131).
        function New-TrigDef([bool]$WithSchedule = $true, [string]$Var = 'true', [switch]$NoVar) {
            $ciJson = '{"branchFilters":[],"pathFilters":[],"settingsSourceType":2,"batchChanges":false,"maxConcurrentBuildsPerBranch":1,"triggerType":"continuousIntegration"}'
            $schedJson = '{"schedules":[{"branchFilters":["+refs/heads/develop"],"timeZoneId":"India Standard Time","startHours":23,"startMinutes":0,"daysToBuild":79,"scheduleJobId":"a5cebf79-6d73-488a-b95e-9afa0920a014","scheduleOnlyWithChanges":false}],"triggerType":"schedule"}'
            $trig = if ($WithSchedule) { "[$ciJson,$schedJson]" } else { "[$ciJson]" }
            $vars = if (-not $NoVar) { "{`"enableSchedule`":{`"value`":`"$Var`"},`"PipelineClassification_Audited`":{`"value`":`"Production`"}}" } else { '{"PipelineClassification_Audited":{"value":"Production"}}' }
            [pscustomobject]@{ Content = "{`"id`":391732,`"revision`":131,`"createdDate`":`"2025-03-04T05:06:07.123Z`",`"variables`":$vars,`"triggers`":$trig,`"repository`":{`"id`":`"5a66e6b0`",`"type`":`"TfsGit`"},`"process`":{`"type`":2,`"yamlFilename`":`".pipelines/BCM/EA.Can.yml`"}}" }
        }
        function Set-GuardState([string]$Dir, [hashtable]$G) {
            $p = Join-Path $Dir 'state.json'
            $s = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable
            $s.scheduleGuards = @{ 'BCM-EACAN' = $G }
            $s | ConvertTo-Json -Depth 12 | Set-Content $p -Encoding UTF8
        }
        function Mock-Step5Succeeded {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?buildIds=' } -MockWith {
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 5002; definition = @{ id = 391732 }; status = 'completed'; result = 'succeeded'; queueTime = '2026-11-16T11:28:14Z' }) }
            }
        }
    }

    It 'removes only the schedule trigger (+ flips the variable) in one PUT, saves it, and warns about the YAML cron' {
        Mock-Step5Succeeded
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=' } -MockWith { [pscustomobject]@{ value = @() } }
        Mock Invoke-WebRequest { New-TrigDef }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 132 } }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/git/repositories/5a66e6b0/items\?' -and $Uri -match 'version=develop' } -MockWith { "trigger: none`nschedules:`n- cron: `"30 17 * * *`"`n  branches:`n    include:`n    - develop`n" }
        $d = New-Env -Guard $script:TrigGuard
        $r = Invoke-Guard $d 'Sync'
        $r.Results[0].status | Should -Be 'disabled'
        $r.Results[0].schedules | Should -Be 'develop Mon,Tue,Wed,Thu,Sun 23:00 India Standard Time'
        $r.Results[0].warning | Should -Match "YAML on 'develop'.*cron"
        $r.NotifyEvents | Should -Contain 'schedule-guard-disabled:BCM-EACAN'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            if ($Method -ne 'PUT') { return $false }
            $b = $Body | ConvertFrom-Json -AsHashtable -DateKind String
            @($b.triggers).Count -eq 1 -and $b.triggers[0].triggerType -eq 'continuousIntegration' -and
            $b.variables.enableSchedule.value -eq 'false' -and $b.variables.PipelineClassification_Audited.value -eq 'Production' -and
            $b.revision -eq 131 -and $b.createdDate -eq '2025-03-04T05:06:07.123Z'
        }
        $g = Get-Guard $d
        $g.status | Should -Be 'disabled'
        $g.variableChanged | Should -BeTrue
        ($g.triggersRemovedJson | ConvertFrom-Json)[0].schedules[0].scheduleJobId | Should -Be 'a5cebf79-6d73-488a-b95e-9afa0920a014'
        ([datetime]$g.windowStart).ToUniversalTime().ToString('o') | Should -Match '^2026-11-16T11:28:14'
        $g.warning | Should -Not -BeNullOrEmpty
    }

    It 'skips a variable that is not defined on the pipeline instead of failing' {
        Mock-Step5Succeeded
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=' } -MockWith { [pscustomobject]@{ value = @() } }
        Mock Invoke-WebRequest { New-TrigDef -NoVar }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 132 } }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/git/repositories/' } -MockWith { 'trigger: none' }
        $d = New-Env -Guard $script:TrigGuard
        $r = Invoke-Guard $d 'Sync'
        $r.Results[0].status | Should -Be 'disabled'
        $r.Results[0].note | Should -Match "variable 'enableSchedule' is not defined"
        $r.Results[0].warning | Should -BeNullOrEmpty
        (Get-Guard $d).variableChanged | Should -BeFalse
    }

    It 'is preexisting when there is no schedule trigger and the variable is already off' {
        Mock-Step5Succeeded
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=' } -MockWith { [pscustomobject]@{ value = @() } }
        Mock Invoke-WebRequest { New-TrigDef -WithSchedule $false -Var 'false' }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { throw 'no PUT expected' }
        $d = New-Env -Guard $script:TrigGuard
        $r = Invoke-Guard $d 'Sync'
        $r.Results[0].status | Should -Be 'preexisting'
        $r.Results[0].note | Should -Match 'no schedule trigger'
    }

    It 're-adds exactly the saved trigger and turns the variable back on at approve-bvt' {
        Mock Invoke-WebRequest { New-TrigDef -WithSchedule $false -Var 'false' }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 140 } }
        $d = New-Env -Guard $script:TrigGuard
        Set-GuardState $d @{ status = 'disabled'; variableChanged = $true; triggersRemovedJson = "[$($script:Sched)]"; windowStart = '2026-11-16T11:28:14Z' }
        $r = Invoke-Guard $d 'Restore' @{ Reason = 'approve-bvt' }
        $r.Results[0].status | Should -Be 'restored'
        $r.Results[0].schedules | Should -Match '^develop Mon,Tue,Wed,Thu,Sun 23:00'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            if ($Method -ne 'PUT') { return $false }
            $b = $Body | ConvertFrom-Json -AsHashtable -DateKind String
            $s = @($b.triggers | Where-Object { $_.triggerType -eq 'schedule' })
            @($b.triggers).Count -eq 2 -and $s.Count -eq 1 -and $s[0].schedules[0].daysToBuild -eq 79 -and
            $s[0].schedules[0].scheduleJobId -eq 'a5cebf79-6d73-488a-b95e-9afa0920a014' -and $s[0].schedules[0].branchFilters[0] -eq '+refs/heads/develop' -and
            $b.variables.enableSchedule.value -eq 'true'
        }
        (Get-Guard $d).schedulesRestored | Should -Match 'develop'
    }

    It 'does not duplicate a schedule someone already re-added' {
        Mock Invoke-WebRequest { New-TrigDef -WithSchedule $true -Var 'true' }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { throw 'no PUT expected' }
        $d = New-Env -Guard $script:TrigGuard
        Set-GuardState $d @{ status = 'disabled'; variableChanged = $true; triggersRemovedJson = "[$($script:Sched)]" }
        $r = Invoke-Guard $d 'Restore'
        $r.Results[0].status | Should -Be 'restored'
        $r.Results[0].note | Should -Match 'schedule trigger is already present'
    }

    It 'cancels runs ZED did not queue during the window, leaves ZED''s runs and older queued runs, and never cancels twice' {
        $d = New-Env -Step5 'completed' -Step6 'in-progress' -Guard $script:TrigGuard
        Set-GuardState $d @{ status = 'disabled'; variableChanged = $true; triggersRemovedJson = "[$($script:Sched)]"; disabledByRunId = 5002; windowStart = '2026-11-16T11:28:14Z' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=391732' } -MockWith {
            [pscustomobject]@{ value = @(
                [pscustomobject]@{ id = 5002; status = 'inProgress'; queueTime = '2026-11-16T11:28:14Z'; sourceBranch = 'refs/heads/master'; reason = 'manual'; requestedFor = @{ displayName = 'ZED'; uniqueName = 'owner@microsoft.com' } }
                [pscustomobject]@{ id = 7001; buildNumber = 'd.1'; status = 'inProgress'; queueTime = '2026-11-16T17:04:00Z'; sourceBranch = 'refs/heads/develop'; reason = 'manual'; requestedFor = @{ displayName = 'Sourabh Gholap'; uniqueName = 'sgholap@microsoft.com' } }
                [pscustomobject]@{ id = 7002; status = 'notStarted'; queueTime = '2026-09-27T10:55:49Z'; sourceBranch = 'refs/heads/develop'; reason = 'manual'; requestedFor = @{ displayName = 'A'; uniqueName = 'a@microsoft.com' } }
                [pscustomobject]@{ id = 7003; status = 'notStarted'; queueTime = '2026-11-16T17:30:04Z'; sourceBranch = 'refs/heads/develop'; reason = 'schedule'; requestedFor = @{ displayName = 'Microsoft.VisualStudio.Services.TFS'; uniqueName = '00000002-0000-8888-8000-000000000000@2c895908-04e0-4952-89fd-54b0046d6288' } }
            ) }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PATCH' } -MockWith { [pscustomobject]@{ status = 'cancelling' } }
        Mock Invoke-WebRequest { throw 'must not read the definition' }
        $r = Invoke-Guard $d 'Sync'
        $r.Success | Should -BeTrue
        $r.NotifyEvents | Should -Be @('schedule-guard-run-cancelled:BCM-EACAN:7001', 'schedule-guard-run-cancelled:BCM-EACAN:7003')
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -match '/builds/7001\?' -and $Body -eq '{"status":"cancelling"}' }
        $c = @((Get-Guard $d).cancelledRuns)
        $c.Count | Should -Be 2
        ($c | Where-Object runId -eq 7001).requestedForEmail | Should -Be 'sgholap@microsoft.com'
        ($c | Where-Object runId -eq 7003).reason | Should -Be 'schedule'
        ($c | Where-Object runId -eq 7003).requestedForEmail | Should -BeNullOrEmpty

        # next tick: the same runs are still listed while cancelling -> no second PATCH, no new email
        $r2 = Invoke-Guard $d 'Sync'
        $r2.NotifyEvents | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'keeps cancelling while the definition edit fails for lack of permission, and reports a failed cancel once' {
        Mock-Step5Succeeded
        Mock Invoke-WebRequest { New-TrigDef }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { throw 'TF50309: insufficient permissions to edit the build pipeline' }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=391732' } -MockWith {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 7001; status = 'inProgress'; queueTime = '2026-11-16T17:04:00Z'; sourceBranch = 'refs/heads/develop'; reason = 'manual'; requestedFor = @{ displayName = 'S'; uniqueName = 's@microsoft.com' } }) }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PATCH' } -MockWith { throw 'TF215106: access denied' }
        $d = New-Env -Step5 'completed' -Guard $script:TrigGuard
        $r = Invoke-Guard $d 'Sync'
        (Get-Guard $d).status | Should -Be 'disable-failed'
        $r.NotifyEvents | Should -Contain 'schedule-guard-failed:BCM-EACAN'

        $r2 = Invoke-Guard $d 'Sync'   # now in the window (disable-failed) -> cancel attempted
        $r2.NotifyEvents | Should -Contain 'schedule-guard-cancel-failed:BCM-EACAN:7001'
        $r2.NotifyEvents | Should -Not -Contain 'schedule-guard-failed:BCM-EACAN'
        $r3 = Invoke-Guard $d 'Sync'
        $r3.NotifyEvents | Should -BeNullOrEmpty
        (@((Get-Guard $d).cancelledRuns) | Where-Object runId -eq 7001).status | Should -Be 'cancel-failed'
    }

    It 'stops cancelling once Step 6 is signed off, and never cancels without cancelForeignRuns' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=' } -MockWith { throw 'must not list runs' }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PUT' } -MockWith { [pscustomobject]@{ revision = 141 } }
        Mock Invoke-WebRequest { New-TrigDef -WithSchedule $false -Var 'false' }
        $d = New-Env -Step5 'completed' -Step6 'completed' -Guard $script:TrigGuard
        Set-GuardState $d @{ status = 'disabled'; variableChanged = $true; triggersRemovedJson = "[$($script:Sched)]"; windowStart = '2026-11-16T11:28:14Z' }
        (Invoke-Guard $d 'Sync').Results[0].status | Should -Be 'restored'

        $g2 = [ordered]@{ pauseScheduleTriggers = $true }
        $d2 = New-Env -Step5 'completed' -Step6 'in-progress' -Guard $g2
        Set-GuardState $d2 @{ status = 'disabled'; triggersRemovedJson = "[$($script:Sched)]"; windowStart = '2026-11-16T11:28:14Z' }
        @((Invoke-Guard $d2 'Sync').Results).Count | Should -Be 0
    }

    It 'Preview lists runs it would cancel without cancelling or writing state' {
        $d = New-Env -Step5 'completed' -Step6 'in-progress' -Guard $script:TrigGuard
        Set-GuardState $d @{ status = 'disabled'; windowStart = '2026-11-16T11:28:14Z' }
        $before = Get-Content (Join-Path $d 'state.json') -Raw
        Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'builds\?definitions=391732' } -MockWith {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 7001; status = 'inProgress'; queueTime = '2026-11-16T17:04:00Z'; sourceBranch = 'refs/heads/develop'; reason = 'manual'; requestedFor = @{ displayName = 'S'; uniqueName = 's@microsoft.com' } }) }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'PATCH' } -MockWith { throw 'no PATCH in preview' }
        $r = Invoke-Guard $d 'Sync' @{ Preview = $true }
        $r.Results[0].status | Should -Be 'would-cancel'
        $r.NotifyEvents | Should -BeNullOrEmpty
        Get-Content (Join-Path $d 'state.json') -Raw | Should -Be $before
    }
}

Describe 'scheduleGuard wiring' {
    It 'watcher runs the guard as a throttled side-channel on every tick and during the sleep; cold resume too' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match 'Invoke-ScheduleGuard\.ps1'
        $w | Should -Match 'scheduleGuardPollIntervalSeconds'
        ([regex]::Matches($w, '(?m)^\s+Invoke-ScheduleGuardSideChannel\s*$')).Count | Should -Be 2
        $w | Should -Match "-split ':', 3"
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match 'Invoke-ScheduleGuard\.ps1'
        $c | Should -Match 'ScheduleGuardSideChannel'
        $c | Should -Match 'disabled\|preexisting\|disable-failed'
    }
}
