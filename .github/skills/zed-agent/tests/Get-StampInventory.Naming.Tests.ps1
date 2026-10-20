<#
    Regression tests for Get-StampInventory.ps1:
      - kusto.production.serviceFilter is substituted into {{SERVICE_FILTER}}
      - inventory.stampNaming.partitionSuffixPattern folds per-partition Kusto names
      - SDS short StampIds ('eus-01') reconcile against Kusto full names ('eus-pod01-tst1')
      - reconciliation is scoped to the SDS cloud (no cross-cloud key collisions)
      - sovereign SDS short ids are expanded with the cloud layout

    Every fixture is SYNTHETIC (stampTag 'tst', ServiceName 'tst'); no network,
    no az, no real Kusto. Learned from release 2026-10 Step 10 (1,581 drift rows
    caused by an empty serviceFilter + SDS/Kusto naming mismatch).
#>
BeforeAll {
    $script:srcScripts = Resolve-Path (Join-Path $PSScriptRoot '..\scripts')

    function script:New-InvFixture {
        param(
            [string[]]$KustoStamps,
            [hashtable]$SdsClouds = @{ Public = @('eus-01', 'we-02') },
            $StampNaming = $null,
            [string]$ServiceFilter = "ServiceName == 'tst'"
        )
        $root    = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $scripts = Join-Path $root '.github\skills\zed-agent\scripts'
        $queries = Join-Path $root '.github\skills\zed-agent\queries'
        New-Item -ItemType Directory -Path $scripts, $queries -Force | Out-Null
        Copy-Item (Join-Path $script:srcScripts 'Get-StampInventory.ps1')        $scripts
        Copy-Item (Join-Path $script:srcScripts 'Get-StampInventoryFromSds.ps1') $scripts

        # Stub ASC: synthetic clouds sharing layout 'pod01' (like real Public/Fairfax).
        $asc = @{
            source = 'snapshot'; path = 'stub'
            data = @{ Clouds = @(
                @{ Name = 'Canary';  Layout = 'can02'; DataCenters = @(
                    @{ ShortName = 'ea';  Ev2RegionName = 'eastasia';     Ev2Geography = 'Asia'; DatacenterType = @('ACTIVE') }) }
                @{ Name = 'Public';  Layout = 'pod01'; DataCenters = @(
                    @{ ShortName = 'eus'; Ev2RegionName = 'eastus';       Ev2Geography = 'US';     DatacenterType = @('ACTIVE') }
                    @{ ShortName = 'we';  Ev2RegionName = 'westeurope';   Ev2Geography = 'Europe'; DatacenterType = @('ACTIVE') }
                    @{ ShortName = 'ne';  Ev2RegionName = 'northeurope';  Ev2Geography = 'Europe'; DatacenterType = @('ACTIVE') }
                    @{ ShortName = 'ea';  Ev2RegionName = 'eastasia';     Ev2Geography = 'Asia';   DatacenterType = @('ACTIVE') }) }
                @{ Name = 'Fairfax'; Layout = 'pod01'; DataCenters = @(
                    @{ ShortName = 'ugv'; Ev2RegionName = 'usgovvirginia'; Ev2Geography = 'USGov'; DatacenterType = @('ACTIVE') }) }
            ) }
        }
        $ascJson = ($asc | ConvertTo-Json -Depth 10 -Compress).Replace("'", "''")
        Set-Content -Path (Join-Path $scripts 'Get-AzureServiceConfig.ps1') -Encoding UTF8 -Value @"
[CmdletBinding()]
param([string]`$CachePath,[string]`$SnapshotPath,[int]`$MaxAgeHours,[switch]`$NoCache,[switch]`$PreferCache)
'$ascJson' | ConvertFrom-Json
"@

        Set-Content -Path (Join-Path $queries 'Prod.kql') -Encoding UTF8 -Value @'
T | where {{SERVICE_FILTER}} | where {{STAMP_PREFIX_FILTER}} | summarize make_set(DeploymentUnit) by StampName
'@

        # SDS whose stamps carry only StampId (mirrors BCM: sdsFieldMapping.stampNamePath = StampId).
        $sds = @{
            '$schema' = 'https://aka.ms/phobosweb/schema/2022/sds'
            Metadata  = @{ ServiceShortName = 'tst' }
            CloudSettings = @($SdsClouds.Keys | ForEach-Object {
                @{ CloudName = $_; StampSettings = @($SdsClouds[$_] | ForEach-Object { @{ StampId = $_ } }) }
            })
        }
        $sds | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $root 'sds.json') -Encoding UTF8

        $inventory = @{ driftToleranceCount = 0; production = @{ approvalRequired = $true } }
        if ($StampNaming) { $inventory.stampNaming = $StampNaming }
        $cfg = @{
            service = @{ name = 'TST'; stampTag = 'tst' }
            kusto   = @{ production = @{
                cluster = 'https://fake.kusto.example.net/'; database = 'db'; queryFile = 'Prod.kql'
                serviceFilter = $ServiceFilter; stampPrefixFilter = @()
                clusterTypeExtraction = @{ mode = 'deployment-unit-substring' } } }
            sds = @{ 'TST-PROD' = @{ repo = 'r'; branch = 'main'; path = 'sds.json'; fileName = 'sds.json'; localClonePath = $root } }
            sdsFieldMapping = @{ stampNamePath = 'StampId' }
            inventory = $inventory
        }
        $cfgPath = Join-Path $root 'service-config.json'
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath -Encoding UTF8

        # Canned Kusto response (index-based Tables[0] shape).
        $rows = [System.Collections.ArrayList]::new()
        foreach ($k in $KustoStamps) { [void]$rows.Add(@($k, @("$k-sf"))) }
        $global:ZedInvTestKustoResp = [pscustomobject]@{ Tables = @([pscustomobject]@{
            Columns = @([pscustomobject]@{ ColumnName = 'StampName' }, [pscustomobject]@{ ColumnName = 'set_DeploymentUnit' })
            Rows    = $rows.ToArray() }) }

        [pscustomobject]@{
            Script     = Join-Path $scripts 'Get-StampInventory.ps1'
            ConfigPath = $cfgPath
            QueriesDir = $queries
            CachePath  = Join-Path $root 'cache\inventory.json'
        }
    }

    function script:Invoke-Inv {
        param($Fx, [string]$Cloud)
        $a = @{ Scope = 'production'; PipelineKey = 'TST-PROD'; ServiceConfigPath = $Fx.ConfigPath
                QueriesDir = $Fx.QueriesDir; InventoryCachePath = $Fx.CachePath }
        if ($Cloud) { $a.Cloud = $Cloud }
        & $Fx.Script @a
    }

    $script:Bcmish = @{ partitionSuffixPattern = '-p[0-9]+[a-z]*' }
}

AfterAll { Remove-Variable -Name ZedInvTestKustoResp -Scope Global -ErrorAction SilentlyContinue }

Describe 'Get-StampInventory — service filter and stamp naming' {
    BeforeEach {
        Mock az { 'fake-token' }
        Mock Invoke-RestMethod { $global:ZedInvTestKustoResp }
    }

    Context 'service filter' {
        It 'substitutes kusto.production.serviceFilter into {{SERVICE_FILTER}}' {
            $fx = New-InvFixture -KustoStamps @('eus-pod01-tst1', 'we-pod01-tst2')
            $null = Invoke-Inv $fx
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Body -match "where ServiceName == 'tst'" }
        }
        It 'falls back to 1 == 1 when serviceFilter is empty (back-compat)' {
            $fx = New-InvFixture -KustoStamps @('eus-pod01-tst1') -ServiceFilter ''
            $null = Invoke-Inv $fx
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Body -match 'where 1 == 1 \|' }
        }
    }

    Context 'partition folding (inventory.stampNaming.partitionSuffixPattern)' {
        It 'folds per-partition names into the base stamp when configured' {
            $fx = New-InvFixture -StampNaming $script:Bcmish -KustoStamps @(
                'eus-pod01-tst1', 'eus-pod01-tst1-p1a', 'eus-pod01-tst1-p1b', 'we-pod01-tst2')
            $r = Invoke-Inv $fx
            @($r.stamps | Where-Object stampName -eq 'eus-pod01-tst1').Count | Should -Be 1
            @($r.stamps).Count | Should -Be 2
            @($r.drift | Where-Object { $_.reason -like 'stamp name does not match grammar*' }).Count | Should -Be 0
            @($r.stampNaming.foldedPartitions).Count | Should -Be 2
            $r.stampNaming.foldedPartitions[0].to | Should -Be 'eus-pod01-tst1'
        }
        It 'folds a partition-only name even when the base row is absent' {
            $fx = New-InvFixture -StampNaming $script:Bcmish -KustoStamps @('eus-pod01-tst1-p2c', 'we-pod01-tst2')
            $r = Invoke-Inv $fx
            $r.stamps.stampName | Should -Contain 'eus-pod01-tst1'
        }
        It 'keeps partition names as grammar drift when folding is not configured (opt-in)' {
            $fx = New-InvFixture -KustoStamps @('eus-pod01-tst1', 'eus-pod01-tst1-p1a', 'we-pod01-tst2')
            $r = Invoke-Inv $fx
            ($r.drift | Where-Object stampName -eq 'eus-pod01-tst1-p1a').reason | Should -BeLike 'stamp name does not match grammar*'
            @($r.stampNaming.foldedPartitions).Count | Should -Be 0
        }
        It 'never truncates a name whose remainder is not a valid stamp' {
            # 'eus-pod01-p1' = stampTag 'p', index '1'; base 'eus-pod01' is not a stamp.
            $fx = New-InvFixture -StampNaming $script:Bcmish -KustoStamps @('eus-pod01-p1', 'eus-pod01-tst1', 'we-pod01-tst2')
            $r = Invoke-Inv $fx
            ($r.drift | Where-Object stampName -eq 'eus-pod01-p1').reason | Should -BeLike "serviceTag 'p'*"
            @($r.stampNaming.foldedPartitions).Count | Should -Be 0
        }
    }

    Context 'SDS reconciliation by {shortName}-{index} key' {
        It 'pairs SDS short StampIds with Kusto full names (01 == 1, 02 == 2)' {
            $fx = New-InvFixture -KustoStamps @('eus-pod01-tst1', 'we-pod01-tst2')
            $r = Invoke-Inv $fx
            $r.sdsReconciliation.matchedCount | Should -Be 2
            @($r.sdsReconciliation.sdsOnly).Count   | Should -Be 0
            @($r.sdsReconciliation.kustoOnly).Count | Should -Be 0
            $r.sdsReconciliation.withinTolerance | Should -BeTrue
            @($r.drift).Count | Should -Be 0
        }
        It 'still reports genuine drift on both sides' {
            $fx = New-InvFixture -KustoStamps @('eus-pod01-tst1', 'we-pod01-tst2', 'ne-pod01-tst1') `
                                 -SdsClouds @{ Public = @('eus-01', 'we-02', 'we-03') }
            $r = Invoke-Inv $fx
            $r.sdsReconciliation.kustoOnly | Should -Be @('ne-pod01-tst1')
            $r.sdsReconciliation.sdsOnly   | Should -Be @('we-03')
            $r.sdsReconciliation.driftCount | Should -Be 2
            $r.sdsReconciliation.withinTolerance | Should -BeFalse
            ($r.drift | Where-Object side -eq 'kustoOnly').stampName | Should -Be 'ne-pod01-tst1'
            ($r.drift | Where-Object side -eq 'sdsOnly').stampName   | Should -Be 'we-03'
        }
        It 'compares only Kusto stamps in the reconciled cloud and cannot collide across clouds' {
            # Canary 'ea-can02-tst1' and Public SDS 'ea-01' share key 'ea-1' but different clouds.
            $fx = New-InvFixture -KustoStamps @('ea-can02-tst1', 'eus-pod01-tst1', 'we-pod01-tst2') `
                                 -SdsClouds @{ Public = @('eus-01', 'we-02', 'ea-01'); Canary = @('ea-01') }
            $r = Invoke-Inv $fx
            $r.sdsReconciliation.cloud | Should -Be 'Public'
            $r.sdsReconciliation.kustoOnly | Should -Not -Contain 'ea-can02-tst1'
            $r.sdsReconciliation.kustoOutOfScope.stampName | Should -Be 'ea-can02-tst1'
            $r.sdsReconciliation.kustoOutOfScope.cloud     | Should -Be 'Canary'
            $r.sdsReconciliation.sdsOnly | Should -Be @('ea-01')
        }
    }

    Context 'sovereign cloud (SDS is the sole source)' {
        It 'expands SDS short ids with the cloud layout so ASC validation passes' {
            $fx = New-InvFixture -KustoStamps @() -SdsClouds @{ Public = @('eus-01'); Fairfax = @('ugv-01') }
            $r = Invoke-Inv $fx -Cloud 'Fairfax'
            $r.stamps.stampName | Should -Be 'ugv-pod01-tst1'
            $r.stamps.cloud     | Should -Be 'Fairfax'
            @($r.drift).Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    Context 'config validation' {
        It 'throws when sdsStampIdPattern lacks the required named groups' {
            $fx = New-InvFixture -KustoStamps @('eus-pod01-tst1') -StampNaming @{ sdsStampIdPattern = '^([a-z]+)-([0-9]+)$' }
            { Invoke-Inv $fx } | Should -Throw "*named group '(?<shortName>...)'*"
        }
    }
}
