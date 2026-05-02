BeforeAll {
    . "$PSScriptRoot\..\scripts\Register-WatcherTask.ps1"
}

Describe 'Register-WatcherTask' {
    Context 'Register action' {
        BeforeEach {
            Mock Register-ReleaseWatcherTask { }
        }

        It 'calls Register-ReleaseWatcherTask with correct task name' {
            $result = Register-WatcherTask -Action register -ReleaseId '2026-04' -RepoRoot 'C:\test'
            $result.success | Should -BeTrue
            $result.taskName | Should -Be 'BDP-ReleaseWatcher-2026-04'
            $result.action | Should -Be 'registered'
            Should -Invoke Register-ReleaseWatcherTask -Times 1
        }

        It 'passes pwsh as the executable' {
            Register-WatcherTask -Action register -ReleaseId '2026-04' -RepoRoot 'C:\test'
            Should -Invoke Register-ReleaseWatcherTask -Times 1 -ParameterFilter { $Execute -eq 'pwsh' }
        }

        It 'uses correct working directory' {
            Register-WatcherTask -Action register -ReleaseId '2026-04' -RepoRoot 'C:\test'
            Should -Invoke Register-ReleaseWatcherTask -Times 1 -ParameterFilter { $WorkingDir -eq 'C:\test' }
        }
    }

    Context 'Unregister action' {
        It 'unregisters an existing scheduled task' {
            Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = 'BDP-ReleaseWatcher-2026-04' } }
            Mock Unregister-ScheduledTask { } -Verifiable

            $result = Register-WatcherTask -Action unregister -ReleaseId '2026-04'
            $result.success | Should -BeTrue
            $result.action | Should -Be 'unregistered'
            Should -InvokeVerifiable
        }

        It 'succeeds silently when task does not exist' {
            Mock Get-ScheduledTask { $null }
            Mock Unregister-ScheduledTask { }

            $result = Register-WatcherTask -Action unregister -ReleaseId '2026-04'
            $result.success | Should -BeTrue
            Should -Invoke Unregister-ScheduledTask -Times 0
        }
    }
}
