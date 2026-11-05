#Requires -Modules Pester
<#
    Tests for Invoke-HealthSideChannel.ps1: per-wave tier planning, state.releaseHealth bookkeeping,
    notification queue (early-warning de-duplication, final verdict), Pending and Mark.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Health.Fixtures.ps1')
    $script:Side = Join-Path $HealthDir 'Invoke-HealthSideChannel.ps1'
    $script:NewRelease = {
        param([hashtable]$ReleaseHealth = @{ enabled = $true; mode = 'advisory' }, [int]$Step = 9)
        $r = New-HealthTestRepo -ReleaseHealth $ReleaseHealth
        $dir = Join-Path $r.Root '.zed-agent\releases\Svc2610'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        @{ releaseId = 'Svc2610'; buildNumber = '3.0.886.0'; branch = 'master'; currentStep = $Step; status = 'running' } | ConvertTo-Json | Set-Content (Join-Path $dir 'state.json') -Encoding UTF8
        $r.Root
    }
    $script:State = { param($root) (Get-Content (Join-Path $root '.zed-agent\releases\Svc2610\state.json') -Raw | ConvertFrom-Json).releaseHealth }
    $script:RunAt = { param($root, $at, [switch]$Regression) & $Side -Action Run -ReleaseId Svc2610 -RepoRoot $root -AsOf (& $Utc $at) -KqlInvoker (New-HealthFixtureInvoker -Regression:$Regression) }
    $script:Repos = [System.Collections.Generic.List[string]]::new()
}

AfterAll { foreach ($r in $Repos) { if (Test-Path $r) { Remove-Item -Recurse -Force $r } } }

Describe 'Start gating' {
    It 'does nothing when release health is disabled' {
        $root = & $NewRelease @{ enabled = $false; mode = 'shadow' }; $Repos.Add($root)
        (& $Side -Action Start -ReleaseId Svc2610 -RepoRoot $root).reason | Should -Be 'releaseHealth disabled'
    }
    It 'waits until the canary is deployed' {
        $root = & $NewRelease -Step 3; $Repos.Add($root)
        (& $Side -Action Start -ReleaseId Svc2610 -RepoRoot $root).reason | Should -Be 'canary not deployed yet'
    }
}

Describe 'Run planning and notifications' {
    It 'runs a tripwire soon after deployment and queues nothing for a healthy wave' {
        $root = & $NewRelease; $Repos.Add($root)
        & $RunAt $root '2026-10-29T12:40:00Z' | Should -Match 'tripwire -> INCONCLUSIVE'
        $rh = & $State $root
        $rh.releaseVersion | Should -Be $Rel
        $rh.previousVersion | Should -Be $Prev
        $wave = $rh.waves.PSObject.Properties.Value | Select-Object -First 1
        @($wave.units) | Should -Be @('frc-coord', 'uks-coord', 'sds-coord')
        @($wave.reports).Count | Should -Be 1
        @($rh.notifications.PSObject.Properties).Count | Should -Be 0
        $rh.running | Should -BeNullOrEmpty
    }
    It 'queues one early warning for a Sev1 and does not repeat it on the next run' {
        $root = & $NewRelease; $Repos.Add($root)
        & $RunAt $root '2026-10-29T12:40:00Z' -Regression | Out-Null
        $pending = @(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root)
        $pending.Count | Should -Be 1
        $pending[0].kind | Should -Be 'early-warning'
        $pending[0].eventKey | Should -Be 'release-health-early-warning'
        Test-Path $pending[0].html | Should -BeTrue
        $pending[0].subject | Should -Match 'Svc2610'
        & $RunAt $root '2026-10-29T13:20:00Z' -Regression | Out-Null
        @(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root).Count | Should -Be 1
    }
    It 'issues the final verdict once and then stops checking the wave' {
        $root = & $NewRelease; $Repos.Add($root)
        & $RunAt $root '2026-10-30T12:00:00Z' | Should -Match 'final -> GO'
        $n = @(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root)
        $n.Count | Should -Be 1
        $n[0].kind | Should -Be 'verdict'
        $n[0].eventKey | Should -Be 'release-health-go'
        ((& $State $root).waves.PSObject.Properties.Value | Select-Object -First 1).finalVerdict | Should -Be 'GO'
        & $RunAt $root '2026-10-30T13:00:00Z' | Should -Not -Match 'final'
    }
    It 'issues a NO-GO verdict for a regressed wave' {
        $root = & $NewRelease; $Repos.Add($root)
        & $RunAt $root '2026-10-30T12:00:00Z' -Regression | Should -Match 'final -> NO-GO'
        (@(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root) | Where-Object kind -eq 'verdict').eventKey | Should -Be 'release-health-no-go'
    }
}

Describe 'Agent RCA annotation and owner decisions' {
    BeforeAll {
        $script:Root2 = & $NewRelease; $Repos.Add($Root2)
        & $RunAt $Root2 '2026-10-30T12:00:00Z' | Out-Null
        $script:N = (@(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $Root2))[0]
        $script:RcaPath = Join-Path $Root2 'rca.json'
    }
    It 'adds RCA, escalates GO to HOLD and switches the event key' {
        $report = Get-Content $N.json -Raw | ConvertFrom-Json
        $fid = @($report.findings)[0].id
        $rca = @{ agentNotes = 'Checked CRP dependency.'; escalate = @{ verdict = 'HOLD'; reason = 'Restore latency trend needs another cycle' } }
        if ($fid) { $rca.findings = @{ $fid = @{ classification = 'environmental'; confidence = 'high'; summary = 'Control stamps show the same shift'; recommendation = 'None' } } }
        $rca | ConvertTo-Json -Depth 6 | Set-Content $RcaPath
        $out = & $Side -Action Annotate -ReleaseId Svc2610 -RepoRoot $Root2 -NotificationId $N.id -RcaFile $RcaPath
        $out.verdict | Should -Be 'HOLD'
        $out.eventKey | Should -Be 'release-health-hold'
        $out.subject | Should -Match 'HOLD'
        (Get-Content $N.html -Raw) | Should -Match 'Checked CRP dependency'
        ((& $State $Root2).waves.PSObject.Properties.Value | Select-Object -First 1).finalVerdict | Should -Be 'HOLD'
    }
    It 'refuses to lower a verdict' {
        @{ escalate = @{ verdict = 'GO'; reason = 'x' } } | ConvertTo-Json | Set-Content $RcaPath
        { & $Side -Action Annotate -ReleaseId Svc2610 -RepoRoot $Root2 -NotificationId $N.id -RcaFile $RcaPath } | Should -Throw '*escalat*'
    }
    It 'records owner overrides and accepted findings and reports them in Status' {
        & $Side -Action Override -ReleaseId Svc2610 -RepoRoot $Root2 -WaveId $N.waveId -Verdict GO -Reason 'Owner reviewed' -By 'owner' | Out-Null
        & $Side -Action Accept -ReleaseId Svc2610 -RepoRoot $Root2 -FindingId 'F-123' -Reason 'known' -By 'owner' | Out-Null
        $s = & $Side -Action Status -ReleaseId Svc2610 -RepoRoot $Root2
        $s.waves[0].finalVerdict | Should -Be 'GO'
        $s.waves[0].override.decidedBy | Should -Be 'owner'
        $s.accepted[0].findingId | Should -Be 'F-123'
        { & $Side -Action Override -ReleaseId Svc2610 -RepoRoot $Root2 -WaveId 'nope' -Verdict GO -Reason 'x' } | Should -Throw '*not found*'
    }
}

Describe 'Pending and Mark' {
    It 'removes sent notifications and gives up after three failed attempts' {
        $root = & $NewRelease; $Repos.Add($root)
        & $RunAt $root '2026-10-30T12:00:00Z' -Regression | Out-Null
        $id = (@(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root))[0].id
        1..2 | ForEach-Object { & $Side -Action Mark -ReleaseId Svc2610 -RepoRoot $root -NotificationId $id }
        (@(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root))[0].status | Should -Be 'agent-failed'
        & $Side -Action Mark -ReleaseId Svc2610 -RepoRoot $root -NotificationId $id
        @(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root).Count | Should -Be 0
    }
    It 'marks a delivered notification as sent' {
        $root = & $NewRelease; $Repos.Add($root)
        & $RunAt $root '2026-10-30T12:00:00Z' | Out-Null
        $id = (@(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root))[0].id
        & $Side -Action Mark -ReleaseId Svc2610 -RepoRoot $root -NotificationId $id -Success
        (& $State $root).notifications.$id.status | Should -Be 'sent'
        @(& $Side -Action Pending -ReleaseId Svc2610 -RepoRoot $root).Count | Should -Be 0
        (Get-Content (Join-Path $root '.zed-agent\releases\Svc2610\audit.jsonl') -Raw) | Should -Match 'health-notification'
    }
}
