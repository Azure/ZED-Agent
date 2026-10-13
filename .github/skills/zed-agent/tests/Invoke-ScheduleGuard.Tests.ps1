<#
.SYNOPSIS
    Pester tests for Invoke-ScheduleGuard.ps1 (pause a canary pipeline's own scheduled
    deployments after ZED's Step 5 run succeeds; restore at Step 6 sign-off). ADO is mocked.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-ScheduleGuard.ps1'

    function New-Env {
        param([string]$Step5 = 'in-progress', [string]$Step6 = 'pending', [bool]$TestMode = $false, [object[]]$RunIds = @(5001, 5002))
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $steps = 1..16 | ForEach-Object { [ordered]@{ number = $_; name = "s$_"; status = 'pending' } }
        1..4 | ForEach-Object { $steps[$_ - 1].status = 'completed' }
        $steps[4].status = $Step5; $steps[5].status = $Step6
        [ordered]@{ releaseId = '2026-11'; steps = $steps; triggeredPipelines = @{ '5' = $RunIds } } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'state.json') -Encoding UTF8
        [ordered]@{ releaseId = '2026-11'; currentBranch = 'releases/bcm-2611'; testMode = $TestMode } |
            ConvertTo-Json | Set-Content (Join-Path $dir 'release.json') -Encoding UTF8
        [ordered]@{
            canary = [ordered]@{
                'BCM-CANARY' = [ordered]@{ name = 'c'; id = 391437; sourceBranch = 'x'; templateParameters = @{} }
                'BCM-EACAN'  = [ordered]@{ name = 'e'; id = 391732; sourceBranch = 'x'; templateParameters = @{}; scheduleGuard = [ordered]@{ variable = 'enableSchedule'; disabledValue = 'false'; enabledValue = 'true' } }
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

Describe 'scheduleGuard wiring' {
    It 'watcher and cold resume run the guard sync every tick' {
        $w = Get-Content (Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1') -Raw
        $w | Should -Match 'Invoke-ScheduleGuard\.ps1'
        $c = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1') -Raw
        $c | Should -Match 'Invoke-ScheduleGuard\.ps1'
        $c | Should -Match 'ScheduleGuardSideChannel'
    }
}
