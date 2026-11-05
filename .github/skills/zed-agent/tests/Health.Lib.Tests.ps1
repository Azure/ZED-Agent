#Requires -Modules Pester
<#
    Unit tests for scripts/Health/HealthLib.ps1 — the pure statistics, cohort, signal and verdict
    rules of the release health check. Scenarios mirror the BCM2610_2 Day2 simulation and the
    BCM2609-2 (3.0.881.0, TaskCanceledException) backtest.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Health\HealthLib.ps1')
    $script:Cmp = [pscustomobject]@{ baseWindow = 'previousDay'; confirmWindow = 'previousWeek'; investigateRelativeDelta = 0.10; falseDiscoveryRate = 0.01; minExtraFailures = 20; singleSubscriptionShare = 0.8; controlEnabled = $true; controlPurityMin = 0.99 }
    $script:Utc = { param($s) [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') }

    # Outcome rows: release units r1,r2; control c1. $spec: cohort|window -> @{ total; svc; code; user }
    function New-OutcomeRows {
        param([hashtable]$Spec, [string]$Op = 'Backup', [string]$Code = 'ServiceErr', [double]$TopShare = 0.1)
        foreach ($k in $Spec.Keys) {
            $unit, $window = $k -split '\|'
            $s = $Spec[$k]
            $svc = [double]$s.svc; $user = [double]$s.user
            [pscustomobject]@{ Unit = $unit; Window = $window; Operation = $Op; ErrorCode = ''; Total = $s.total - $svc - $user; Failures = 0; TopSubscriptionFailures = 0 }
            if ($svc) { [pscustomobject]@{ Unit = $unit; Window = $window; Operation = $Op; ErrorCode = $(if ($s.code) { $s.code } else { $Code }); Total = $svc; Failures = $svc; TopSubscriptionFailures = [math]::Round($svc * $TopShare) } }
            if ($user) { [pscustomobject]@{ Unit = $unit; Window = $window; Operation = $Op; ErrorCode = 'UserErrorX'; Total = $user; Failures = $user; TopSubscriptionFailures = 0 } }
        }
    }
    $script:UnitCohort = @{ r1 = 'release'; r2 = 'release'; c1 = 'control' }
    $script:Map = @{ ServiceErr = $false; NewServiceErr = $false; UserErrorX = $true }
    $script:Signal = [pscustomobject]@{ id = 'backup'; title = 'Backups'; area = 'Backups'; kind = 'outcomes'; thresholds = [pscustomobject]@{ minSamples = 200; sev1 = [pscustomobject]@{ ratio = 2.0; absDelta = 0.01; maxQ = 0.001 } } }
}

Describe 'Statistics' {
    It 'detects a clear proportion increase and ignores equal rates' {
        (Test-HealthProportion 300 10000 100 10000).p | Should -BeLessThan 0.0001
        (Test-HealthProportion 100 10000 100 10000).p | Should -BeGreaterThan 0.4
    }
    It 'normalizes counts by exposure in the rate test' {
        $t = Test-HealthRate 200 2000000 100 1000000
        $t.ratio | Should -Be 1
        $t.p | Should -BeGreaterThan 0.4
    }
    It 'applies Benjamini-Hochberg monotonically' {
        $tests = @(0.001, 0.02, 0.03, 0.5) | ForEach-Object { [pscustomobject]@{ p = $_ } }
        Set-HealthQValue -Tests $tests
        $tests[0].q | Should -Be 0.004
        $tests[1].q | Should -BeLessOrEqual $tests[2].q
        $tests[3].q | Should -Be 0.5
    }
}

Describe 'Text, KQL and version helpers' {
    It 'normalizes GUIDs, quoted customer names and numbers into one signature' {
        $rules = @([pscustomobject]@{ pattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'; replacement = '<guid>' },
                   [pscustomobject]@{ pattern = "'[^']*'"; replacement = "'<v>'" }, [pscustomobject]@{ pattern = '[0-9]+'; replacement = '#' })
        $a = ConvertTo-HealthSignature "Resource group 'rg-a' not found for 1b2c3d4e-0000-1111-2222-333344445555 retry 3" $rules
        $b = ConvertTo-HealthSignature "Resource group 'rg-other' not found for 99999999-aaaa-bbbb-cccc-dddddddddddd retry 12" $rules
        $a | Should -Be $b
        ConvertTo-HealthKqlSignatureExpression -Rules $rules | Should -Match '^substring\(trim\(.*replace_regex\('
    }
    It 'throws on unresolved placeholders' {
        { Expand-HealthQuery -Query 'T | where X in ({{UNITS}}) and Y == {{NOPE}}' -Values @{ UNITS = "dynamic(['a'])" } } | Should -Throw '*{{NOPE}}*'
    }
    It 'ignores placeholders in whole-line comments' {
        $q = Expand-HealthQuery -Query "// never join {{WINDOWS}} here`nT | where U in ({{UNITS}})" -Values @{ UNITS = "dynamic(['a'])"; WINDOWS = "datatable(A:int)[`n1`n]" }
        $q | Should -Be "T | where U in (dynamic(['a']))"
        Expand-HealthQuery -Query "// {{NOT_DEFINED}}`nT" | Should -Be 'T'
    }
    It 'builds one wide window row per unit for a 1:1 lookup' {
        $w = @([pscustomobject]@{ Unit = 'u1'; Cohort = 'release'; Window = 'current'; WStart = '2026-10-29T10:00:00Z'; WEnd = '2026-10-29T12:00:00Z' },
               [pscustomobject]@{ Unit = 'u1'; Cohort = 'release'; Window = 'previousDay'; WStart = '2026-10-28T10:00:00Z'; WEnd = '2026-10-28T12:00:00Z' })
        $t = ConvertTo-HealthKqlWindowsWide -Windows $w
        $t | Should -Match "^datatable\(Unit:string, Cohort:string, currentStart:datetime"
        $t | Should -Match "'u1', 'release', datetime\(2026-10-29T10:00:00\.000Z\), datetime\(2026-10-29T12:00:00\.000Z\), datetime\(2026-10-28T10:00:00\.000Z\), datetime\(2026-10-28T12:00:00\.000Z\), datetime\(null\), datetime\(null\)"
        Get-HealthKqlWindowCase | Should -Match "^case\(TIMESTAMP between \(currentStart \.\. currentEnd\), 'current'"
    }
    It 'escapes KQL strings' {
        ConvertTo-HealthKqlString "a'b\c" | Should -Be "'a\'b\\c'"
    }
    It 'builds the telemetry version from build number and branch' {
        Get-HealthReleaseVersion -BuildNumber '3.0.886.0' -Branch 'master' | Should -Be '3.0.886.0-master'
        Get-HealthReleaseVersion -BuildNumber '3.0.1898.2' -Branch 'refs/heads/releases/commonMSbuildTesting' | Should -Be '3.0.1898.2-releases_commonMSbuildTesting'
    }
    It 'builds a time filter from merged window ranges' {
        $w = @([pscustomobject]@{ WStart = '2026-10-29T10:00:00Z'; WEnd = '2026-10-29T12:00:00Z' }, [pscustomobject]@{ WStart = '2026-10-29T11:00:00Z'; WEnd = '2026-10-29T13:00:00Z' },
               [pscustomobject]@{ WStart = '2026-10-22T10:00:00Z'; WEnd = '2026-10-22T12:00:00Z' })
        $f = ConvertTo-HealthKqlTimeFilter -Windows $w
        ([regex]::Matches($f, 'between')).Count | Should -Be 2
        $f | Should -Match 'datetime\(2026-10-29T10:00:00\.000Z\) \.\. datetime\(2026-10-29T13:00:00\.000Z\)'
        ConvertTo-HealthKqlTimeFilter -Windows @() | Should -Be 'false'
    }
    It 'creates an ADX deep link' {
        Get-HealthAdxLink -Cluster 'https://mabprod1.kusto.windows.net' -Database 'MABKustoProd1' -Query 'T | take 1' | Should -Match '^https://dataexplorer\.azure\.com/clusters/mabprod1/databases/MABKustoProd1\?query='
    }
}

Describe 'Error classification' {
    It 'uses the source map, overrides, regex fallback and null codes' {
        $cls = [pscustomobject]@{ userErrorRegex = '^UserError'; overrides = [pscustomobject]@{ Odd = 'user' } }
        Get-HealthErrorClass 'ServiceErr' $Map $cls | Should -Be 'service'
        Get-HealthErrorClass 'UserErrorX' $Map $cls | Should -Be 'user'
        Get-HealthErrorClass 'Odd' $Map $cls | Should -Be 'user'
        Get-HealthErrorClass 'UserErrorUnknown' $Map $cls | Should -Be 'user'
        Get-HealthErrorClass 'BrandNew' $Map $cls | Should -Be 'unclassified'
        Get-HealthErrorClass 'null' $Map $cls | Should -Be 'unclassified'
        Get-HealthErrorClass '' $Map $cls | Should -Be 'success'
    }
}

Describe 'Cohorts and windows' {
    BeforeAll {
        $now = & $Utc '2026-10-30T12:00:00Z'
        $row = { param($u, $v, $f, $l) [pscustomobject]@{ Unit = $u; Version = $v; FirstSeen = (& $Utc $f); LastSeen = (& $Utc $l); Ops = 1000 } }
        $script:Rows = @(
            & $row 'ccy-coord' '3.0.883.0-master' '2026-10-20' '2026-10-25T09:00:00Z'
            & $row 'ccy-coord' '3.0.886.0-master' '2026-10-25T09:05:00Z' '2026-10-30T11:59:00Z'
            & $row 'ea-coord' '3.0.883.0-master' '2026-10-20' '2026-10-27T00:00:00Z'
            & $row 'ea-coord' '3.0.886.0-master' '2026-10-27T00:00:00Z' '2026-10-30T11:59:00Z'
            & $row 'frc-coord' '3.0.883.0-master' '2026-10-20' '2026-10-29T10:10:00Z'
            & $row 'frc-coord' '3.0.886.0-master' '2026-10-29T10:10:00Z' '2026-10-30T11:59:00Z'
            & $row 'sds-coord' '3.0.883.0-master' '2026-10-20' '2026-10-29T11:28:00Z'
            & $row 'sds-coord' '3.0.886.0-master' '2026-10-29T11:28:00Z' '2026-10-30T11:59:00Z'
            & $row 'eus-coord' '3.0.883.0-master' '2026-10-20' '2026-10-30T11:59:00Z'
            & $row 'old-coord' '3.0.883.0-master' '2026-10-20' '2026-10-28T00:00:00Z'
            & $row 'dev-coord' '3.0.1900.0-develop' '2026-10-20' '2026-10-30T11:59:00Z'
            & $row 'ccy-coord-p1a' '3.0.886.0-master' '2026-10-25' '2026-10-30T11:59:00Z'
        )
        $script:Scope = [pscustomobject]@{ unitRegex = '-coord$'; canaryUnits = @('ccy-coord'); officialVersionPattern = '-(master|release[^-]*)$'; excludeVersionPatterns = @('-develop$', '-users?_') }
        $script:Co = Get-HealthCohorts -Rows $Rows -ReleaseVersion '3.0.886.0-master' -Scope $Scope -AsOf $now -WaveGapMinutes 180 -StageMap @{ 'frc-coord' = 'Day2'; 'sds-coord' = 'Day2' }
    }
    It 'finds release units with telemetry T0 and the previous build' {
        @($Co.Release.Unit) | Should -Be @('ccy-coord', 'ea-coord', 'frc-coord', 'sds-coord')
        $Co.PreviousVersion | Should -Be '3.0.883.0-master'
        ($Co.Release | Where-Object Unit -eq 'frc-coord').T0 | Should -Be (& $Utc '2026-10-29T10:10:00Z')
    }
    It 'uses only active units on the previous build as control and excludes dev/private units' {
        @($Co.Control.Unit) | Should -Be @('eus-coord')
        @($Co.Excluded.Unit) | Should -Contain 'old-coord'
        @($Co.Excluded.Unit) | Should -Contain 'dev-coord'
        @($Co.Units.Unit) | Should -Not -Contain 'ccy-coord-p1a'
    }
    It 'forms a canary wave and splits other waves by T0 gaps, labelled from EV2 stages' {
        @($Co.Waves.Label) | Should -Be @('Canary', 'Wave 1', 'Day2')
        @(($Co.Waves | Where-Object Label -eq 'Day2').Units) | Should -Be @('frc-coord', 'sds-coord')
    }
    It 'builds previousDay windows that end before T0 and match the current length' {
        $rel = @($Co.Release | Where-Object Unit -eq 'frc-coord')
        $w = Get-HealthWindows -ReleaseUnits $rel -ControlUnits $Co.Control -AsOf (& $Utc '2026-10-30T12:00:00Z') -Timing ([pscustomobject]@{ windowStartOffsetMinutes = 15; maxWindowHours = 24; ingestionLagMinutes = 20 })
        $cur = $w | Where-Object { $_.Unit -eq 'frc-coord' -and $_.Window -eq 'current' }
        $pd = $w | Where-Object { $_.Unit -eq 'frc-coord' -and $_.Window -eq 'previousDay' }
        $pd.WEnd | Should -BeLessOrEqual $rel[0].T0.AddMinutes(-5)
        ($pd.WEnd - $pd.WStart) | Should -Be ($cur.WEnd - $cur.WStart)
        @($w | Where-Object Cohort -eq 'control').Count | Should -Be 3
    }
}

Describe 'Outcome signals' {
    It 'raises nothing when the release and the control change together (environmental shift)' {
        $rows = New-OutcomeRows @{ 'r1|current' = @{ total = 50000; svc = 200 }; 'r1|previousDay' = @{ total = 50000; svc = 100 }; 'r2|current' = @{ total = 50000; svc = 200 }; 'r2|previousDay' = @{ total = 50000; svc = 100 }
                                   'c1|current' = @{ total = 100000; svc = 400 }; 'c1|previousDay' = @{ total = 100000; svc = 200 } }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        @($r.findings | Where-Object severity -in 'Sev1', 'Investigate').Count | Should -Be 0
        $r.status | Should -Be 'pass'
    }
    It 'raises Sev1 for a large regression on the release only' {
        $rows = New-OutcomeRows @{ 'r1|current' = @{ total = 50000; svc = 900 }; 'r1|previousDay' = @{ total = 50000; svc = 100 }; 'r2|current' = @{ total = 50000; svc = 900 }; 'r2|previousDay' = @{ total = 50000; svc = 100 }
                                   'c1|current' = @{ total = 100000; svc = 200 }; 'c1|previousDay' = @{ total = 100000; svc = 200 } }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        @($r.findings | Where-Object { $_.severity -eq 'Sev1' -and $_.key -eq 'overall' }).Count | Should -Be 1
    }
    It 'investigates a significant change of at least 10% and ignores 5%' {
        $mk = { param($n) New-OutcomeRows @{ 'r1|current' = @{ total = 500000; svc = $n }; 'r1|previousDay' = @{ total = 500000; svc = 1000 }; 'c1|current' = @{ total = 500000; svc = 1000 }; 'c1|previousDay' = @{ total = 500000; svc = 1000 } } }
        $hit = Measure-HealthOutcomes -Rows (& $mk 1180) -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        @($hit.findings | Where-Object { $_.severity -eq 'Investigate' -and $_.key -eq 'overall' }).Count | Should -Be 1
        $miss = Measure-HealthOutcomes -Rows (& $mk 1050) -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        @($miss.findings | Where-Object key -eq 'overall').Count | Should -Be 0
    }
    It 'excludes user errors from the service-failure rate' {
        $rows = New-OutcomeRows @{ 'r1|current' = @{ total = 50000; svc = 100; user = 3000 }; 'r1|previousDay' = @{ total = 50000; svc = 100; user = 1000 }; 'c1|current' = @{ total = 50000; svc = 100; user = 1000 }; 'c1|previousDay' = @{ total = 50000; svc = 100; user = 1000 } }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        $r.summary.ratio | Should -Be 1
        @($r.findings | Where-Object key -eq 'overall').Count | Should -Be 0
        @($r.findings | Where-Object key -eq 'user-errors').Count | Should -Be 1
    }
    It 'turns failures concentrated in one subscription into a watch item' {
        $rows = New-OutcomeRows -TopShare 0.95 @{ 'r1|current' = @{ total = 50000; svc = 300; code = 'CatalogInternalError' }; 'r1|previousDay' = @{ total = 50000; svc = 10; code = 'CatalogInternalError' }; 'c1|current' = @{ total = 50000; svc = 10; code = 'CatalogInternalError' }; 'c1|previousDay' = @{ total = 50000; svc = 10; code = 'CatalogInternalError' } }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        ($r.findings | Where-Object key -eq 'code|CatalogInternalError').severity | Should -Be 'Watch'
        ($r.findings | Where-Object key -eq 'code|CatalogInternalError').attribution | Should -Be 'single-subscription'
    }
    It 'turns an aggregate increase explained by one subscription into a watch item' {
        $rows = New-OutcomeRows -TopShare 0.95 @{ 'r1|current' = @{ total = 50000; svc = 900 }; 'r1|previousDay' = @{ total = 50000; svc = 100 }; 'c1|current' = @{ total = 100000; svc = 200 }; 'c1|previousDay' = @{ total = 100000; svc = 200 } }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        ($r.findings | Where-Object key -eq 'overall').severity | Should -Be 'Watch'
        ($r.findings | Where-Object key -eq 'overall').attribution | Should -Be 'single-subscription'
        @($r.findings | Where-Object severity -in 'Sev1', 'Investigate').Count | Should -Be 0
    }
    It 'raises Sev1 for a new service error code on two units' {
        $rows = @(New-OutcomeRows @{ 'r1|current' = @{ total = 50000; svc = 0 }; 'r2|current' = @{ total = 50000; svc = 0 }; 'r1|previousDay' = @{ total = 50000; svc = 0 }; 'r1|previousWeek' = @{ total = 50000; svc = 0 }; 'c1|current' = @{ total = 50000; svc = 0 }; 'c1|previousDay' = @{ total = 50000; svc = 0 } })
        $rows += [pscustomobject]@{ Unit = 'r1'; Window = 'current'; Operation = 'Backup'; ErrorCode = 'NewServiceErr'; Total = 15; Failures = 15; TopSubscriptionFailures = 2 }
        $rows += [pscustomobject]@{ Unit = 'r2'; Window = 'current'; Operation = 'Backup'; ErrorCode = 'NewServiceErr'; Total = 15; Failures = 15; TopSubscriptionFailures = 2 }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        ($r.findings | Where-Object key -eq 'code|NewServiceErr').severity | Should -Be 'Sev1'
    }
    It 'raises Sev1 when the workload volume collapses' {
        $rows = New-OutcomeRows @{ 'r1|current' = @{ total = 20000; svc = 10 }; 'r1|previousDay' = @{ total = 50000; svc = 25 }; 'c1|current' = @{ total = 50000; svc = 25 }; 'c1|previousDay' = @{ total = 50000; svc = 25 } }
        $r = Measure-HealthOutcomes -Rows $rows -Signal $Signal -UnitCohort $UnitCohort -UserErrorMap $Map -Comparison $Cmp
        ($r.findings | Where-Object key -eq 'volume').severity | Should -Be 'Sev1'
    }
}

Describe 'Error signatures' {
    BeforeAll {
        $script:SigSignal = [pscustomobject]@{ id = 'errors'; title = 'Error logs'; area = 'Errors'; kind = 'signatures'; thresholds = [pscustomobject]@{ minUnits = 2; newMinCount = 20; sev1 = [pscustomobject]@{ ratio = 5.0; minExtra = 500; maxQ = 0.001 } } }
        $script:Exp = @{ 'release|current' = 20378426; 'release|previousDay' = 20000000; 'control|current' = 580820590; 'control|previousDay' = 580000000 }
        $script:S = { param($c, $w, $sig, $n, $units = 3) [pscustomobject]@{ Cohort = $c; Window = $w; Signature = $sig; Count = $n; Stamps = $units; Instances = $units * 4 } }
    }
    It 'flags the BCM2609-2 TaskCanceledException spike (86x on the release only) as Sev1' {
        $rows = @((& $S 'release' 'current' 'TaskCanceledException in CRP call' 102222 5), (& $S 'release' 'previousDay' 'TaskCanceledException in CRP call' 1170 5),
                  (& $S 'control' 'current' 'TaskCanceledException in CRP call' 33986 38), (& $S 'control' 'previousDay' 'TaskCanceledException in CRP call' 33900 38))
        $r = Measure-HealthSignatures -Rows $rows -Signal $SigSignal -Comparison $Cmp -Exposure $Exp
        ($r.findings | Select-Object -First 1).severity | Should -Be 'Sev1'
    }
    It 'treats signatures that differ only by case as different (KQL is case-sensitive)' {
        $rows = @((& $S 'release' 'current' 'CloudException: The Resource' 21223 17), (& $S 'release' 'previousDay' 'CloudException: The Resource' 21055 17),
                  (& $S 'release' 'previousDay' 'CloudException: The resource' 53 2))
        @((Measure-HealthSignatures -Rows $rows -Signal $SigSignal -Comparison $Cmp -Exposure $Exp).findings).Count | Should -Be 0
    }
    It 'ignores signatures matching ignoreSignatureRegex (user-error log lines)' {
        $rows = @((& $S 'release' 'current' 'StartCiSTask NonRetriableError UserErrorVmNotFound' 1500 3), (& $S 'release' 'previousDay' 'StartCiSTask NonRetriableError UserErrorVmNotFound' 100 3))
        $sig = $SigSignal.PSObject.Copy(); $sig | Add-Member -NotePropertyName ignoreSignatureRegex -NotePropertyValue 'UserError'
        @((Measure-HealthSignatures -Rows $rows -Signal $sig -Comparison $Cmp -Exposure $Exp).findings).Count | Should -Be 0
        @((Measure-HealthSignatures -Rows $rows -Signal $SigSignal -Comparison $Cmp -Exposure $Exp).findings).Count | Should -Be 1
    }
    It 'ignores signatures on a single unit (customer or stamp noise)' {
        $rows = @((& $S 'release' 'current' "Resource group '<v>' not found" 1500 1), (& $S 'release' 'previousDay' "Resource group '<v>' not found" 100 1))
        (Measure-HealthSignatures -Rows $rows -Signal $SigSignal -Comparison $Cmp -Exposure $Exp).findings.Count | Should -Be 0
    }
    It 'treats a candidate seen on another build in the lookback as pre-existing, otherwise Sev1' {
        $rows = @((& $S 'release' 'current' 'Retrying GetILRSasTier#' 27 3))
        $r = Measure-HealthSignatures -Rows $rows -Signal $SigSignal -Comparison $Cmp -Exposure $Exp
        @($r.candidates).Count | Should -Be 1
        $pre = Resolve-HealthNewSignatures -Result $r -HistoryRows @([pscustomobject]@{ Signature = 'Retrying GetILRSasTier#'; Count = 114 }) -Signal $SigSignal
        @($pre.findings).Count | Should -Be 0
        @($pre.preExistingCandidates).Count | Should -Be 1
        $r2 = Measure-HealthSignatures -Rows $rows -Signal $SigSignal -Comparison $Cmp -Exposure $Exp
        $new = Resolve-HealthNewSignatures -Result $r2 -HistoryRows @() -Signal $SigSignal
        $new.findings[0].severity | Should -Be 'Sev1'
    }
}

Describe 'Upgrade lifecycle' {
    BeforeAll {
        $script:LcSignal = [pscustomobject]@{ id = 'upgrade'; title = 'Service upgrade'; area = 'Upgrade'; kind = 'lifecycle'; thresholds = [pscustomobject]@{ dedupeMinutes = 5; loopRestarts = 3; loopWindowMinutes = 60 } }
        $script:Rel = '3.0.886.0-master'
        $script:Ev = { param($u, $inst, $event, $t, $ver = '3.0.886.0-master', $procId = '') [pscustomobject]@{ Unit = $u; RoleInstance = $inst; Service = 'TeeService'; Event = $event; Version = $ver; Timestamp = (& $Utc $t); Pid = $procId } }
        $script:Units = @([pscustomobject]@{ Unit = 'sea' })
    }
    It 'collapses duplicate init lines from one restart (Day2 false positive)' {
        $ev = @((& $Ev 'sea' 'i6' 'stop-requested' '2026-10-29T11:05:00Z' '3.0.883.0-master'), (& $Ev 'sea' 'i6' 'init' '2026-10-29T11:05:10Z'), (& $Ev 'sea' 'i6' 'init' '2026-10-29T11:05:20Z'), (& $Ev 'sea' 'i6' 'init' '2026-10-29T11:05:40Z'))
        $r = Measure-HealthLifecycle -Events $ev -StartFailures @() -ReleaseUnits $Units -Signal $LcSignal -ReleaseVersion $Rel
        @($r.findings).Count | Should -Be 0
        $r.units[0].maxStartsPerWindow | Should -Be 1
    }
    It 'flags a restart loop of distinct restarts within the window' {
        $ev = @((& $Ev 'sea' 'i1' 'init' '2026-10-29T11:00:00Z' $Rel 'a'), (& $Ev 'sea' 'i1' 'init' '2026-10-29T11:15:00Z' $Rel 'b'), (& $Ev 'sea' 'i1' 'init' '2026-10-29T11:40:00Z' $Rel 'c'))
        (Measure-HealthLifecycle -Events $ev -StartFailures @() -ReleaseUnits $Units -Signal $LcSignal -ReleaseVersion $Rel).findings[0].title | Should -Match 'Restart loop'
    }
    It 'flags role start failures on the release build only' {
        $ev = @((& $Ev 'sea' 'i1' 'init' '2026-10-29T11:00:00Z'))
        $sf = @([pscustomobject]@{ Unit = 'sea'; Role = 'TeeWorkerRole'; Version = '3.0.1891.0-develop'; Count = 1; First = '2026-10-29'; Sample = 'OnStart threw exception' })
        @((Measure-HealthLifecycle -Events $ev -StartFailures $sf -ReleaseUnits $Units -Signal $LcSignal -ReleaseVersion $Rel).findings).Count | Should -Be 0
        $sf[0].Version = $Rel
        (Measure-HealthLifecycle -Events $ev -StartFailures $sf -ReleaseUnits $Units -Signal $LcSignal -ReleaseVersion $Rel).findings[0].severity | Should -Be 'Sev1'
    }
    It 'reports a unit without lifecycle events as inconclusive' {
        (Measure-HealthLifecycle -Events @() -StartFailures @() -ReleaseUnits $Units -Signal $LcSignal -ReleaseVersion $Rel).findings[0].severity | Should -Be 'Inconclusive'
    }
}

Describe 'Counters and series' {
    It 'applies ceiling, shift and floor rules' {
        $sig = [pscustomobject]@{ id = 'machines'; title = 'CPU and memory'; area = 'Machines'; kind = 'counters'; counters = @(
            [pscustomobject]@{ name = 'cpu'; label = 'CPU'; rule = 'p95-shift'; ceiling = 80; minDelta = 5 },
            [pscustomobject]@{ name = 'mem'; label = 'Available MB'; rule = 'floor'; floor = 1024 }) }
        $c = { param($u, $w, $n, $p95, $min = 5000) [pscustomobject]@{ Unit = $u; Window = $w; RoleInstance = 'i1'; Counter = $n; Avg = $p95 / 2; P95 = $p95; Min = $min; Max = $p95 } }
        $rows = @((& $c 'r1' 'current' 'cpu' 85), (& $c 'r1' 'previousDay' 'cpu' 30), (& $c 'r2' 'current' 'cpu' 40), (& $c 'r2' 'previousDay' 'cpu' 30),
                  (& $c 'c1' 'current' 'cpu' 30), (& $c 'c1' 'previousDay' 'cpu' 30), (& $c 'r1' 'current' 'mem' 0 900))
        $r = Measure-HealthCounters -Rows $rows -Signal $sig -UnitCohort $UnitCohort -Comparison $Cmp
        ($r.findings | Where-Object key -eq 'ceiling|cpu|r1').severity | Should -Be 'Sev1'
        ($r.findings | Where-Object key -eq 'shift|cpu|r2').severity | Should -Be 'Investigate'
        ($r.findings | Where-Object key -eq 'floor|mem|r1').severity | Should -Be 'Sev1'
    }
    It 'detects sustained memory growth' {
        $sig = [pscustomobject]@{ id = 'mem'; title = 'Committed memory'; area = 'Machines'; kind = 'series'; thresholds = [pscustomobject]@{ maxGrowthPctPerHour = 2; minHours = 6 } }
        $base = & $Utc '2026-10-29T12:00:00Z'
        $rows = 0..9 | ForEach-Object { [pscustomobject]@{ Unit = 'r1'; Role = 'Tee'; Counter = 'committed'; Bucket = $base.AddHours($_); Avg = 1000 * (1 + 0.05 * $_) } }
        (Measure-HealthSeries -Rows $rows -Signal $sig -UnitCohort $UnitCohort).findings[0].severity | Should -Be 'Sev1'
        $flat = 0..9 | ForEach-Object { [pscustomobject]@{ Unit = 'r1'; Role = 'Tee'; Counter = 'committed'; Bucket = $base.AddHours($_); Avg = 1000 + ($_ % 2) } }
        @((Measure-HealthSeries -Rows $flat -Signal $sig -UnitCohort $UnitCohort).findings).Count | Should -Be 0
    }
}

Describe 'Verdict' {
    BeforeAll {
        $script:F = { param($sev, $attr = 'release-correlated') New-HealthFinding -Severity $sev -Area 'A' -SignalId 's' -Key ([guid]::NewGuid()) -Title "$sev finding" -Detail 'd' -Attribution $attr }
    }
    It 'maps findings to NO-GO / HOLD / INCONCLUSIVE / GO' {
        (Get-HealthVerdict -Findings @((& $F 'Sev1'), (& $F 'Investigate'))).verdict | Should -Be 'NO-GO'
        (Get-HealthVerdict -Findings @((& $F 'Investigate'))).verdict | Should -Be 'HOLD'
        (Get-HealthVerdict -Findings @((& $F 'Sev1' 'uncertain'))).verdict | Should -Be 'HOLD'
        (Get-HealthVerdict -Findings @((& $F 'Inconclusive' 'data-quality'))).verdict | Should -Be 'INCONCLUSIVE'
        (Get-HealthVerdict -Findings @() -BakeComplete $false).verdict | Should -Be 'INCONCLUSIVE'
        (Get-HealthVerdict -Findings @((& $F 'Watch' 'single-subscription'))).verdict | Should -Be 'GO'
    }
    It 'never treats a data-quality issue as GO' {
        (Get-HealthVerdict -Findings @() -DataQualityIssues @('stale telemetry')).verdict | Should -Be 'INCONCLUSIVE'
    }
    It 'honours accepted findings, suppressions and owner overrides' {
        $sev = & $F 'Sev1'
        (Get-HealthVerdict -Findings @($sev) -AcceptedIds @($sev.id)).verdict | Should -Be 'GO'
        $sup = & $F 'Investigate'; $sup.suppressed = 'known noise'
        (Get-HealthVerdict -Findings @($sup)).verdict | Should -Be 'GO'
        $o = Get-HealthVerdict -Findings @((& $F 'Investigate')) -Override ([pscustomobject]@{ verdict = 'GO'; decidedBy = 'owner'; reason = 'accepted risk' })
        $o.verdict | Should -Be 'GO'
        $o.reasons[-1] | Should -Match 'Owner override'
    }
    It 'matches suppressions by signal and key, and ignores expired ones' {
        $f = New-HealthFinding -Severity Investigate -Area 'A' -SignalId 'backup' -Key 'code|X' -Title 't' -Detail 'd'
        Test-HealthSuppressed -Finding $f -Suppressions @([pscustomobject]@{ signalId = 'backup'; keyRegex = '^code\|X$'; reason = 'r'; addedBy = 'o' }) | Should -Not -BeNullOrEmpty
        Test-HealthSuppressed -Finding $f -Suppressions @([pscustomobject]@{ signalId = 'backup'; keyRegex = '^code\|X$'; reason = 'r'; addedBy = 'o'; expires = '2020-01-01' }) | Should -BeNullOrEmpty
        Test-HealthSuppressed -Finding $f -Suppressions @([pscustomobject]@{ signalId = 'restore'; reason = 'r'; addedBy = 'o' }) | Should -BeNullOrEmpty
    }
}
