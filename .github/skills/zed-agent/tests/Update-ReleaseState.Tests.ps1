BeforeAll {
    . "$PSScriptRoot\..\scripts\Update-ReleaseState.ps1"
}

Describe 'Update-ReleaseState' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive 'repo'
        $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
        New-Item -ItemType Directory -Path $relDir -Force | Out-Null
        Push-Location $testRoot

        $sampleState = @{
            releaseId = '2026-04'; currentStep = 1; status = 'in-progress'
            lastUpdated = '2026-04-01T10:00:00Z'; lastAgent = 'run'
            steps = @(
                @{ number = 1; name = 'send-reminder'; displayName = 'Send Reminder'; status = 'pending'; startedAt = $null; completedAt = $null; error = $null; metadata = @{} }
                @{ number = 2; name = 'cut-branch'; displayName = 'Cut Branch'; status = 'pending'; startedAt = $null; completedAt = $null; error = $null; metadata = @{} }
            )
            watcherDirective = $null
            approvals = @{ bvt = @{ approved = $false }; rollback = @{ approved = $false }; crb = @{ approved = $false } }
        }
        $sampleState | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $relDir 'state.json') -Encoding UTF8
    }

    AfterEach { Pop-Location }

    Context 'Action: read' {
        It 'reads state.json and returns parsed object' {
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.releaseId | Should -Be '2026-04'
            $state.currentStep | Should -Be 1
            $state.steps.Count | Should -Be 2
        }

        It 'throws when state file does not exist' {
            { Update-ReleaseState -ReleaseId 'nonexistent' -Action read } | Should -Throw '*not found*'
        }
    }

    Context 'Minimal step skeletons ({number,name,status} — e.g. BCM state.json)' {
        It 'adds startedAt / completedAt when the step has none' {
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            @{ releaseId = '2026-04'; lastUpdated = '2026-04-01T10:00:00Z'; steps = @(@{ number = 4; name = 'collect-commits'; status = 'pending' }) } |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $relDir 'state.json') -Encoding UTF8
            { Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 4 -StepStatus 'in-progress' } | Should -Not -Throw
            { Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 4 -StepStatus 'completed' } | Should -Not -Throw
            $s = (Update-ReleaseState -ReleaseId '2026-04' -Action read).steps | Where-Object number -eq 4
            $s.status | Should -Be 'completed'
            $s.startedAt | Should -Not -BeNullOrEmpty
            $s.completedAt | Should -Not -BeNullOrEmpty
        }
    }
    Context 'Action: write' {
        It 'creates .bak before writing' {
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            $newState = '{"releaseId":"2026-04","currentStep":2}'
            Update-ReleaseState -ReleaseId '2026-04' -Action write -DirectiveJson $newState
            Test-Path (Join-Path $relDir 'state.json.bak') | Should -BeTrue
        }

        It 'writes the provided JSON as state' {
            $newState = '{"releaseId":"2026-04","currentStep":5}'
            Update-ReleaseState -ReleaseId '2026-04' -Action write -DirectiveJson $newState
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            $written = Get-Content(Join-Path $relDir 'state.json') -Raw | ConvertFrom-Json
            $written.currentStep | Should -Be 5
        }

        It 'truncation guard: throws when called with no DirectiveJson and no StateProperties' {
            { Update-ReleaseState -ReleaseId '2026-04' -Action write } |
                Should -Throw '*requires either -DirectiveJson*'
        }

        It 'truncation guard: does not truncate the existing file when guard fires' {
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            try { Update-ReleaseState -ReleaseId '2026-04' -Action write } catch { }
            $remaining = Get-Content (Join-Path $relDir 'state.json') -Raw
            $remaining | Should -Not -BeNullOrEmpty
        }

        It 'StateProperties merge: merges single new top-level property into state' {
            Update-ReleaseState -ReleaseId '2026-04' -Action write -StateProperties @{ newProp = 'hello' }
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.newProp | Should -Be 'hello'
        }

        It 'StateProperties merge: overwrites existing top-level property' {
            Update-ReleaseState -ReleaseId '2026-04' -Action write -StateProperties @{ currentStep = 99 }
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.currentStep | Should -Be 99
        }

        It 'StateProperties merge: preserves other existing properties' {
            Update-ReleaseState -ReleaseId '2026-04' -Action write -StateProperties @{ newProp = 'hi' }
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.releaseId | Should -Be '2026-04'
        }

        It 'StateProperties merge: updates lastUpdated from its original value' {
            # Initial state has lastUpdated = '2026-04-01T10:00:00Z' (well in the past)
            Update-ReleaseState -ReleaseId '2026-04' -Action write -StateProperties @{ newProp = 'ts-test' }
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.lastUpdated | Should -Not -BeNullOrEmpty
            # The value must have changed from the seeded '2026-04-01T10:00:00Z'
            $state.lastUpdated | Should -Not -Be '2026-04-01T10:00:00Z'
        }

        It 'StateProperties merge: throws when state file does not exist' {
            { Update-ReleaseState -ReleaseId 'nonexistent' -Action write -StateProperties @{ x = 1 } } |
                Should -Throw '*not found*'
        }
    }

    Context 'Action: update-step' {
        It 'updates step status to in-progress with startedAt' {
            Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 1 -StepStatus 'in-progress'
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.steps[0].status | Should -Be 'in-progress'
            $state.steps[0].startedAt | Should -Not -BeNullOrEmpty
        }

        It 'updates step status to completed with completedAt' {
            Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 1 -StepStatus 'completed'
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.steps[0].status | Should -Be 'completed'
            $state.steps[0].completedAt | Should -Not -BeNullOrEmpty
        }

        It 'throws when step number does not exist' {
            { Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 99 -StepStatus 'completed' } | Should -Throw '*not found*'
        }

        It 'creates .bak before updating' {
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 1 -StepStatus 'completed'
            Test-Path (Join-Path $relDir 'state.json.bak') | Should -BeTrue
        }
    }

    Context 'Action: set-directive' {
        It 'writes watcherDirective into state' {
            $directive = '{"action":"poll-ado-build","target":"https://dev.azure.com/test","pollIntervalSeconds":60}'
            Update-ReleaseState -ReleaseId '2026-04' -Action set-directive -DirectiveJson $directive
            $state = Update-ReleaseState -ReleaseId '2026-04' -Action read
            $state.watcherDirective.action | Should -Be 'poll-ado-build'
            $state.watcherDirective.pollIntervalSeconds | Should -Be 60
        }
    }

    Context 'Audit logging' {
        It 'appends audit entry to audit.jsonl when provided' {
            $entry = '{"timestamp":"2026-04-01T10:00:00Z","actor":"agent","action":"test"}'
            Update-ReleaseState -ReleaseId '2026-04' -Action update-step -StepNumber 1 -StepStatus 'completed' -AuditEntry $entry
            $relDir = Join-Path $testRoot '.zed-agent/releases/2026-04'
            $audit = Get-Content(Join-Path $relDir 'audit.jsonl') -Raw
            $audit | Should -Match '"action":"test"'
        }

        It 'does not create audit file when no audit entry provided' {
            # Use a fresh release to avoid audit leakage from other tests
            $freshDir = Join-Path $testRoot '.zed-agent/releases/2026-05'
            New-Item -ItemType Directory -Path $freshDir -Force | Out-Null
            $freshState = @{ releaseId = '2026-05'; steps = @(@{ number = 1; name = 'test'; status = 'pending'; startedAt = $null; completedAt = $null; error = $null; metadata = @{} }) ; lastUpdated = ''; watcherDirective = $null } | ConvertTo-Json -Depth 10
            $freshState | Set-Content (Join-Path $freshDir 'state.json') -Encoding UTF8
            Update-ReleaseState -ReleaseId '2026-05' -Action update-step -StepNumber 1 -StepStatus 'completed'
            Test-Path (Join-Path $freshDir 'audit.jsonl') | Should -BeFalse
        }
    }
}
