<#
    Shared fixtures for the release-health tests: a scaffolded temp repo and a fake Kusto
    (-KqlInvoker) that returns rows per query name.
    Scenario: 3.0.886.0-master on frc/sds/uks (T0 2026-10-29 10:10-11:28Z), control eus/wus on 3.0.883.0-master.
#>
$script:HealthDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Health'))
$script:Rel = '3.0.886.0-master'; $script:Prev = '3.0.883.0-master'
$script:RelUnits = @('frc-coord', 'sds-coord', 'uks-coord'); $script:CtlUnits = @('eus-coord', 'wus-coord')
$script:T0 = @{ 'frc-coord' = '2026-10-29T10:10:00Z'; 'sds-coord' = '2026-10-29T11:28:00Z'; 'uks-coord' = '2026-10-29T10:40:00Z' }
$script:Utc = { param($s) [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') }

function New-HealthTestRepo {
    param([hashtable]$ReleaseHealth = @{ enabled = $true; mode = 'advisory' })
    $repo = Join-Path ([IO.Path]::GetTempPath()) ("zed-health-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $repo '.github\skills\zed-agent') | Out-Null
    @{ serviceName = 'Svc'; releaseHealth = $ReleaseHealth } | ConvertTo-Json | Set-Content (Join-Path $repo '.github\skills\zed-agent\service-config.json') -Encoding UTF8
    $scaffold = & (Join-Path $script:HealthDir 'New-ServiceHealthSkill.ps1') -ServiceName 'Svc' -RepoRoot $repo -UpdateServiceConfig
    $cfgPath = Join-Path $scaffold.skillDir 'health-config.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.dataSource.cluster = 'https://test.kusto.windows.net'; $cfg.dataSource.database = 'Db'
    $cfg.scope.unitRegex = '-coord$'; $cfg.scope.stageLabels = 'waves'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath -Encoding UTF8
    [pscustomobject]@{ Root = $repo; Scaffold = $scaffold }
}

# $Regression adds a TaskCanceledException spike, a new error code and a CPU ceiling breach.
function New-HealthFixtureInvoker {
    param([switch]$Regression)
    $rel = $script:Rel; $prev = $script:Prev; $relUnits = $script:RelUnits; $ctlUnits = $script:CtlUnits; $t0 = $script:T0; $utc = $script:Utc
    $wins = 'current', 'previousDay', 'previousWeek'
    $regress = [bool]$Regression
    {
        param($Name, $Text)
        if ($Text -match '\{\{') { throw "unexpanded placeholder in $Name" }
        $all = @($relUnits) + @($ctlUnits)
        switch -Regex ($Name) {
            '^cohort$' {
                foreach ($u in $relUnits) {
                    [pscustomobject]@{ Unit = $u; Version = $prev; FirstSeen = '2026-10-20T00:00:00Z'; LastSeen = $t0[$u]; Ops = 1e6 }
                    [pscustomobject]@{ Unit = $u; Version = $rel; FirstSeen = $t0[$u]; LastSeen = '2026-10-30T11:55:00Z'; Ops = 1e6 }
                }
                foreach ($u in $ctlUnits) { [pscustomobject]@{ Unit = $u; Version = $prev; FirstSeen = '2026-10-20T00:00:00Z'; LastSeen = '2026-10-30T11:55:00Z'; Ops = 1e6 } }
            }
            '^exposure$' {
                foreach ($u in $all) { foreach ($w in $wins) { [pscustomobject]@{ Unit = $u; Window = $w; Version = $(if ($u -in $relUnits -and $w -eq 'current') { $rel } else { $prev }); Ops = 1000000 } } }
            }
            '^freshness$' { [pscustomobject]@{ Source = 'Ops'; LagMinutes = 7 }; [pscustomobject]@{ Source = 'Logs'; LagMinutes = 9 } }
            '^workload-outcomes$' {
                foreach ($u in $all) { foreach ($w in $wins) {
                    $svc = 50; if ($regress -and $u -in $relUnits -and $w -eq 'current') { $svc = 400 }
                    [pscustomobject]@{ Unit = $u; Window = $w; Operation = 'Backup'; ErrorCode = ''; Total = 50000 - $svc - 100; Failures = 0; TopSubscriptionFailures = 0 }
                    [pscustomobject]@{ Unit = $u; Window = $w; Operation = 'Backup'; ErrorCode = 'ServiceErr'; Total = $svc; Failures = $svc; TopSubscriptionFailures = 5 }
                    [pscustomobject]@{ Unit = $u; Window = $w; Operation = 'Backup'; ErrorCode = 'UserErrorQuota'; Total = 100; Failures = 100; TopSubscriptionFailures = 30 }
                    if ($regress -and $u -in $relUnits -and $w -eq 'current') { [pscustomobject]@{ Unit = $u; Window = $w; Operation = 'Backup'; ErrorCode = 'BrandNewCrash'; Total = 40; Failures = 40; TopSubscriptionFailures = 4 } }
                } }
            }
            '^latency$' {
                foreach ($c in 'release', 'control') { foreach ($w in $wins) { [pscustomobject]@{ Cohort = $c; Window = $w; Operation = 'Backup'; N = 150000; P50 = 900; P95 = 4000 } } }
            }
            '^error-signatures$' {
                foreach ($c in 'release', 'control') { foreach ($w in $wins) {
                    [pscustomobject]@{ Cohort = $c; Window = $w; Signature = 'Known transient # retry'; Count = $(if ($c -eq 'release') { 3000 } else { 6000 }); Stamps = 3; Instances = 12 }
                    $tc = if ($regress -and $c -eq 'release' -and $w -eq 'current') { 90000 } elseif ($c -eq 'release') { 1000 } else { 2000 }
                    [pscustomobject]@{ Cohort = $c; Window = $w; Signature = 'TaskCanceledException in CRP call'; Count = $tc; Stamps = 3; Instances = 12 }
                } }
            }
            '^error-signatures-history$' { }
            '^machine-counters$' {
                foreach ($u in $all) { foreach ($w in $wins) {
                    $cpu = if ($regress -and $u -eq 'frc-coord' -and $w -eq 'current') { 92 } else { 35 }
                    [pscustomobject]@{ Unit = $u; Window = $w; RoleInstance = 'i0'; Counter = '\Processor(_Total)\% Processor Time'; Avg = $cpu / 2; P95 = $cpu; Min = 1; Max = $cpu }
                    [pscustomobject]@{ Unit = $u; Window = $w; RoleInstance = 'i0'; Counter = '\Memory\Available MBytes'; Avg = 6000; P95 = 7000; Min = 5000; Max = 8000 }
                } }
            }
            '^memory-growth$' {
                foreach ($u in $relUnits) { 0..12 | ForEach-Object { [pscustomobject]@{ Unit = $u; Role = 'Worker'; Counter = 'committed'; Bucket = (& $utc '2026-10-29T12:00:00Z').AddHours($_); Avg = 4e9 + ($_ % 2) * 1e6 } } }
            }
            '^upgrade$' {
                foreach ($u in $relUnits) { [pscustomobject]@{ Unit = $u; RoleInstance = 'i0'; Service = 'Worker'; Event = 'init'; Version = $rel; Timestamp = (& $utc $t0[$u]).AddMinutes(2); Pid = '1' } }
            }
            '^upgrade-start-failures$' { }
            '^drilldown:' { [pscustomobject]@{ RequestId = 'r-1'; Message = 'boom' } }
            default { throw "unexpected query $Name" }
        }
    }.GetNewClosure()
}
