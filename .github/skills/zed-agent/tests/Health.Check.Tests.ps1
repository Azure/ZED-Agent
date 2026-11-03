#Requires -Modules Pester
<#
    End-to-end tests for Invoke-ReleaseHealthCheck.ps1 against a temp repo scaffolded with
    New-ServiceHealthSkill.ps1. Kusto is replaced by -KqlInvoker fixtures keyed by query name.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Health.Fixtures.ps1')
    $script:TestRepo = New-HealthTestRepo
    $script:Repo = $TestRepo.Root; $script:Scaffold = $TestRepo.Scaffold
    $script:AsOf = & $Utc '2026-10-30T12:00:00Z'
    function New-Invoker([switch]$Regression) { [pscustomobject]@{ Invoker = (New-HealthFixtureInvoker -Regression:$Regression) } }
    $script:Run = {
        param($Invoker, [hashtable]$Extra = @{})
        $p = @{ ReleaseId = 'Svc2610'; ReleaseVersion = $Rel; RepoRoot = $Repo; AsOf = $AsOf; KqlInvoker = $Invoker; UserErrorMap = @{ ServiceErr = $false; UserErrorQuota = $true } }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        & (Join-Path $HealthDir 'Invoke-ReleaseHealthCheck.ps1') @p
    }
}
AfterAll { if ($Repo -and (Test-Path $Repo)) { Remove-Item -Recurse -Force $Repo } }

Describe 'Skeleton scaffold' {
    It 'creates the service skill with SKILL.md, config and queries and points service-config at it' {
        Test-Path (Join-Path $Scaffold.skillDir 'SKILL.md') | Should -BeTrue
        @(Get-ChildItem (Join-Path $Scaffold.skillDir 'queries') -Filter *.kql).Count | Should -BeGreaterOrEqual 12
        (Get-Content (Join-Path $Scaffold.skillDir 'SKILL.md') -Raw) | Should -Not -Match '__SERVICE__|__SKILL_NAME__'
        (Get-Content (Join-Path $Repo '.github\skills\zed-agent\service-config.json') -Raw | ConvertFrom-Json).releaseHealth.skillPath | Should -Be '.github/skills/svc-release-health'
    }
    It 'keeps existing files unless -Force' {
        $again = & (Join-Path $HealthDir 'New-ServiceHealthSkill.ps1') -ServiceName 'Svc' -RepoRoot $Repo
        @($again.created).Count | Should -Be 0
    }
}

Describe 'Invoke-ReleaseHealthCheck' {
    It 'returns GO for a healthy release and writes JSON + HTML' {
        $fx = New-Invoker
        $r = & $Run $fx.Invoker
        $r.dataQuality.issues | Should -BeNullOrEmpty
        @($r.findings | Where-Object severity -in 'Sev1', 'Investigate').Count | Should -Be 0
        $r.verdict.verdict | Should -Be 'GO'
        $r.previousVersion | Should -Be $Prev
        @($r.control.units) | Should -Be $CtlUnits
        Test-Path $r.files.json | Should -BeTrue
        (Get-Content $r.files.html -Raw) | Should -Match 'GO'
        @($r.queries | Where-Object error).Count | Should -Be 0
    }
    It 'returns NO-GO for a regression and names the signature, the new error code and the CPU ceiling' {
        $r = & $Run (New-Invoker -Regression).Invoker
        $r.verdict.verdict | Should -Be 'NO-GO'
        $sev1 = @($r.findings | Where-Object severity -eq 'Sev1')
        ($sev1.title -join "`n") | Should -Match 'TaskCanceledException'
        ($sev1.title -join "`n") | Should -Match 'BrandNewCrash'
        @($sev1 | Where-Object key -like 'ceiling|*|frc-coord').Count | Should -Be 1
        (Get-Content $r.files.html -Raw) | Should -Match 'NO-GO'
    }
    It 'never returns GO from a tripwire run' {
        (& $Run (New-Invoker).Invoker @{ Tier = 'tripwire' }).verdict.verdict | Should -Be 'INCONCLUSIVE'
    }
    It 'returns INCONCLUSIVE before the minimum bake time' {
        (& $Run (New-Invoker).Invoker @{ AsOf = (& $Utc '2026-10-29T15:00:00Z') }).verdict.verdict | Should -Be 'INCONCLUSIVE'
    }
    It 'honours an accepted Sev1 finding id' {
        $first = & $Run (New-Invoker -Regression).Invoker @{ NoFiles = $true }
        $ids = @($first.findings | Where-Object severity -in 'Sev1', 'Investigate' | ForEach-Object id)
        (& $Run (New-Invoker -Regression).Invoker @{ NoFiles = $true; AcceptedIds = $ids }).verdict.verdict | Should -Be 'GO'
    }
    It 'reports a stamp that stops sending telemetry as Sev1' {
        $fx = New-Invoker
        $inner = $fx.Invoker
        $silent = { param($Name, $Text) $rows = @(& $inner $Name $Text); if ($Name -eq 'exposure') { $rows | Where-Object { -not ($_.Unit -eq 'uks-coord' -and $_.Window -eq 'current') } } else { $rows } }.GetNewClosure()
        $r = & $Run $silent @{ NoFiles = $true }
        @($r.findings | Where-Object key -eq 'silent|uks-coord').severity | Should -Be 'Sev1'
    }
    It 'runs a configured RCA drill-down' {
        $d = & $Run (New-Invoker).Invoker @{ Drilldown = 'errors-by-request'; DrilldownParams = @{ requestIds = @('r-1') } }
        $d.rows[0].RequestId | Should -Be 'r-1'
    }
    It 'records a failing signal query as a data-quality issue (never GO)' {
        $fx = New-Invoker
        $inner = $fx.Invoker
        $broken = { param($Name, $Text) if ($Name -eq 'latency') { throw 'Kusto timeout' }; & $inner $Name $Text }.GetNewClosure()
        $r = & $Run $broken @{ NoFiles = $true }
        $r.verdict.verdict | Should -Be 'INCONCLUSIVE'
        ($r.dataQuality.issues -join ' ') | Should -Match "latency' failed"
    }

    It 'leaves a unit whose current window fails version purity out of every comparison (paired windows)' {
        $inner = New-HealthFixtureInvoker -Regression
        $mixed = { param($Name, $Text)
            $rows = @(& $inner $Name $Text)
            if ($Name -eq 'exposure') { $rows; [pscustomobject]@{ Unit = 'uks-coord'; Window = 'current'; Version = $Prev; Ops = 100000 } } else { $rows } }.GetNewClosure()
        $r = & $Run $mixed @{ NoFiles = $true }
        ($r.dataQuality.notes -join ' ') | Should -Match 'Left uks-coord out'
        @($r.findings | Where-Object key -eq 'volume').Count | Should -Be 0
        ($r.findings | Where-Object severity -eq 'Sev1').title -join ' ' | Should -Match 'TaskCanceledException'
    }
}

Describe 'Invoke-HealthKql' {
    BeforeAll { . (Join-Path $HealthDir 'HealthKusto.ps1') }
    It 'returns rows and fails on in-band partial query failures' {
        Mock Get-HealthKustoToken { 'tok' }
        Mock Invoke-RestMethod { [pscustomobject]@{ Tables = @([pscustomobject]@{ Columns = @([pscustomobject]@{ ColumnName = 'A' }, [pscustomobject]@{ ColumnName = 'B' }); Rows = @(, @(1, 'x')) }) } }
        $rows = Invoke-HealthKql -Cluster 'https://c.kusto.windows.net' -Database 'D' -Query 'T'
        $rows[0].B | Should -Be 'x'
        Mock Invoke-RestMethod { [pscustomobject]@{ Tables = @([pscustomobject]@{ Columns = @([pscustomobject]@{ ColumnName = 'A' }); Rows = @([pscustomobject]@{ Exceptions = @([pscustomobject]@{ error = [pscustomobject]@{ code = 'LimitsExceeded'; message = 'join exceeded the memory budget' } }) }) }) } }
        { Invoke-HealthKql -Cluster 'https://c.kusto.windows.net' -Database 'D' -Query 'T' } | Should -Throw '*partial query failure*LimitsExceeded*'
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }
}