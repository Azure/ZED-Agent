Describe 'Release-Watcher' {
    BeforeAll {
        $watcherScript = "$PSScriptRoot\..\scripts\Release-Watcher.ps1"
    }

    Context 'Script structure' {
        It 'script file exists and has valid PowerShell syntax' {
            Test-Path $watcherScript | Should -BeTrue
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($watcherScript, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0
        }

        It 'has ReleaseId mandatory parameter' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'param\s*\(' 
            $content | Should -Match '\[Parameter\(Mandatory\)\]'
            $content | Should -Match '\$ReleaseId'
        }
    }

    Context 'Directive parsing' {
        It 'handles poll-ado-build and poll-ado-pipelines action patterns' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'poll-ado-pipelines'
            $content | Should -Match 'poll-ado-build|poll-ado-pipeline|poll-onedrive-file'
        }

        It 'handles wait-timer action with scheduledAt datetime' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'wait-timer'
            $content | Should -Match 'scheduledAt'
        }

        It 'uses copilot --agent=ZedAgent for invocation' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'copilot\s+--agent=ZedAgent'
        }

        It 'uses --allow-all --autopilot --no-ask-user flags' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match '--allow-all'
            $content | Should -Match '--autopilot'
            $content | Should -Match '--no-ask-user'
        }
    }

    Context 'Multi-pipeline polling' {
        It 'iterates over dir.targets for poll-ado-pipelines' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'dir\.targets'
            $content | Should -Match 'allDone'
            $content | Should -Match 'anyFailed'
        }

        It 'writes updated target statuses back to state file' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'ConvertTo-Json.*Set-Content.*stateFile'
        }
    }

    Context 'Exponential backoff' {
        It 'implements retry with exponential backoff (max 3 retries)' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'maxRetries.*=.*3|retryCount.*-ge.*maxRetries'
            $content | Should -Match 'Pow|baseDelay'
        }
    }

    Context 'Lock file management' {
        It 'writes watcher.lock with PID' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'watcher\.lock'
            $content | Should -Match '\$PID'
        }
    }

    Context 'Exit conditions' {
        It 'exits when release status is completed or stopped' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'completed.*stopped|stopped.*completed'
        }
    }

    Context 'Missed schedule detection' {
        It 'detects missed schedule when delay exceeds 30 minutes' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'delayMin.*-gt.*30'
            $content | Should -Match 'missedNotified'
        }

        It 'invokes agent with missed schedule message' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'missed schedule'
        }

        It 'sets missedNotified flag to prevent duplicate notifications' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match 'missedNotified.*=.*\$true'
        }
    }

    Context 'Default poll interval' {
        It 'defaults to 600 seconds (10 min) when pollIntervalSeconds not set' {
            $content = Get-Content $watcherScript -Raw
            $content | Should -Match '600'
        }
    }
}
