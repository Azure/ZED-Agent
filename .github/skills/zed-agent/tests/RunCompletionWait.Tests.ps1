Describe 'RunCompletionWaitLib — serialization wait on real ADO completion' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\scripts\lib\RunCompletionWaitLib.ps1')
        $watcherScript = Join-Path $PSScriptRoot '..\scripts\Release-Watcher.ps1'
        $coldResume    = Join-Path $PSScriptRoot '..\scripts\Invoke-ColdResume.ps1'
        function New-Target([string]$Url, [string]$Status = $null) {
            $o = [pscustomobject]@{ url = $Url; label = $Url }
            if ($Status) { $o | Add-Member -NotePropertyName status -NotePropertyValue $Status }
            return $o
        }
    }

    It 'is NOT done while any run is still inProgress (the canary-deployed shortcut is not applied)' {
        # Regression: BCM-CANARY (deploymentDoneWhen) was marked 'deployed' at once and the
        # serialization wait completed immediately, re-invoking the agent in a loop.
        $targets = @( (New-Target 'run/185113899'), (New-Target 'run/186677698') )
        $runs = @{ 'run/185113899' = @{ id = 185113899; status = 'inProgress' }; 'run/186677698' = @{ id = 186677698; status = 'inProgress' } }
        $r = Update-RunCompletionTargets -Targets $targets -GetRun { param($t) [pscustomobject]$runs[$t.url] }
        $r.AllDone | Should -BeFalse
        $targets[0].adoStatus | Should -Be 'inProgress'
        $targets[0].PSObject.Properties['status'] | Should -BeNullOrEmpty
        $targets[1].checkedAt | Should -Not -BeNullOrEmpty
    }

    It 'a pre-existing deployed status does not count as done' {
        $targets = @( (New-Target 'run/1' 'deployed') )
        $r = Update-RunCompletionTargets -Targets $targets -GetRun { param($t) [pscustomobject]@{ id = 1; status = 'inProgress' } }
        $r.AllDone | Should -BeFalse
        $targets[0].status | Should -Be 'deployed'
    }

    It 'is done only when every run reports status completed — any result, failed included' {
        $targets = @( (New-Target 'run/a'), (New-Target 'run/b') )
        $runs = @{ 'run/a' = @{ id = 1; status = 'completed'; result = 'failed'; finishTime = '2026-10-21T00:00:00Z' }
                   'run/b' = @{ id = 2; status = 'completed'; result = 'succeeded'; finishTime = '2026-10-21T01:00:00Z' } }
        $r = Update-RunCompletionTargets -Targets $targets -GetRun { param($t) [pscustomobject]$runs[$t.url] }
        $r.AllDone | Should -BeTrue
        $targets[0].status | Should -Be 'completed'
        $targets[0].result | Should -Be 'failed'
        @($r.Completed).Count | Should -Be 2
    }

    It 'one completed + one running is not done; completed targets are not re-queried' {
        $targets = @( (New-Target 'run/a' 'completed'), (New-Target 'run/b') )
        $script:queried = @()
        $r = Update-RunCompletionTargets -Targets $targets -GetRun { param($t) $script:queried += $t.url; [pscustomobject]@{ status = 'inProgress' } }
        $r.AllDone | Should -BeFalse
        $script:queried | Should -Be @('run/b')
    }

    It 'an empty target list never completes (fail safe)' {
        (Update-RunCompletionTargets -Targets @() -GetRun { throw 'unused' }).AllDone | Should -BeFalse
    }

    It 'a lookup error propagates (watcher retry/backoff path), it is never treated as completed' {
        $targets = @( (New-Target 'run/a') )
        { Update-RunCompletionTargets -Targets $targets -GetRun { throw 'HTTP 503' } } | Should -Throw '*503*'
        $targets[0].PSObject.Properties['status'] | Should -BeNullOrEmpty
    }

    It 'Release-Watcher dot-sources the lib and routes waitForRunCompletion directives to it' {
        $c = Get-Content $watcherScript -Raw
        $c | Should -Match "lib\\RunCompletionWaitLib\.ps1"
        $c | Should -Match 'waitForRunCompletion'
        $c | Should -Match 'Update-RunCompletionTargets'
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($watcherScript, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'Invoke-ColdResume treats only completed targets as done for waitForRunCompletion' {
        $c = Get-Content $coldResume -Raw
        $c | Should -Match "waitForRunCompletion"
        $c | Should -Match "if \(\`$t\.status -ne 'completed'\) \{ \`$allDone = \`$false \}"
    }
}
