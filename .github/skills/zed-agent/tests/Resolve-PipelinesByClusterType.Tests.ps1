BeforeAll {
    $script:resolverSrc = Resolve-Path "$PSScriptRoot\..\scripts\Resolve-PipelinesByClusterType.ps1"

    function New-TestFixture {
        param(
            [Parameter(Mandatory)] $InventoryResult,
            [Parameter(Mandatory)] [string]$Mode,
            [hashtable]$ClusterTypeMap = @{ sfmc = 'SVC-SFMC'; sfrp = 'SVC-SFRP' },
            [hashtable]$CanarySection  = @{
                'SVC-SFMC' = @{ clusterType = 'sfmc'; templateParameters = @{} }
                'SVC-SFRP' = @{ clusterType = 'sfrp'; templateParameters = @{} }
            }
        )
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        Copy-Item -Path $script:resolverSrc -Destination (Join-Path $dir 'Resolve-PipelinesByClusterType.ps1') -Force

        # Stub Get-StampInventory.ps1 — emits the canned result the test wants.
        $invJson = ($InventoryResult | ConvertTo-Json -Depth 20 -Compress).Replace("'", "''")
        $stub = @"
[CmdletBinding()]
param([string]`$Scope,[string]`$ServiceConfigPath,[string]`$QueriesDir,[switch]`$NoCache,[switch]`$PreferCache,[string]`$Cloud)
'$invJson' | ConvertFrom-Json
"@
        Set-Content -Path (Join-Path $dir 'Get-StampInventory.ps1') -Value $stub -Encoding UTF8

        $catalog = [pscustomobject]@{
            canary        = [pscustomobject]$CanarySection
            canaryRouting = [pscustomobject]@{ mode = $Mode; clusterTypeMap = [pscustomobject]$ClusterTypeMap }
        }
        $catalogPath = Join-Path $dir 'pipeline-catalog.json'
        ($catalog | ConvertTo-Json -Depth 20) | Set-Content -Path $catalogPath -Encoding UTF8

        $config = [pscustomobject]@{
            service = [pscustomobject]@{ serviceTag = 'TEST' }
            inventory = [pscustomobject]@{ canary = [pscustomobject]@{ stamps = @() } }
        }
        $cfgPath = Join-Path $dir 'service-config.json'
        ($config | ConvertTo-Json -Depth 20) | Set-Content -Path $cfgPath -Encoding UTF8

        [pscustomobject]@{
            Dir         = $dir
            Resolver    = Join-Path $dir 'Resolve-PipelinesByClusterType.ps1'
            CatalogPath = $catalogPath
            ConfigPath  = $cfgPath
            QueriesDir  = $dir
        }
    }
}

Describe 'Resolve-PipelinesByClusterType — Layer 2 inventory + drift' {

    Context 'cluster-type mode, clean inventory' {
        It 'returns intersection of liveClusterTypes and clusterTypeMap' {
            $inv = [pscustomobject]@{
                scope    = 'canary'
                cloud    = 'Public'
                stampTag = 'test'
                stamps   = @(
                    [pscustomobject]@{ stampName = 'TEST-PROD-CO1-test-sfmc-eus2-01'; clusterType = 'sfmc' }
                    [pscustomobject]@{ stampName = 'TEST-PROD-CO1-test-sfrp-eus2-01'; clusterType = 'sfrp' }
                )
                drift    = @()
                sources  = [pscustomobject]@{}
                kusto    = [pscustomobject]@{ ranAt = '2025-01-01T00:00:00Z'; durationMs = 42 }
            }
            $fx = New-TestFixture -InventoryResult $inv -Mode 'cluster-type'
            $r = & $fx.Resolver -Scope canary -CatalogPath $fx.CatalogPath -ServiceConfigPath $fx.ConfigPath -QueriesDir $fx.QueriesDir
            $r.mode | Should -Be 'cluster-type'
            @($r.resolved).pipelineKey | Sort-Object | Should -Be @('SVC-SFMC','SVC-SFRP')
            @($r.drift).Count | Should -Be 0
            @($r.stamps).Count | Should -Be 2
        }
    }

    Context 'cluster-type mode, drift present' {
        BeforeEach {
            $script:driftInv = [pscustomobject]@{
                scope  = 'canary'
                stamps = @([pscustomobject]@{ stampName = 'TEST-PROD-CO1-test-sfmc-eus2-01'; clusterType = 'sfmc' })
                drift  = @([pscustomobject]@{ stampName = 'BOGUS-01'; reason = 'shortName not in resolved cloud' })
                sources = [pscustomobject]@{}
                kusto   = [pscustomobject]@{ ranAt = '2025-01-01T00:00:00Z'; durationMs = 1 }
            }
        }

        It 'throws DRIFT_HALT by default' {
            $fx = New-TestFixture -InventoryResult $script:driftInv -Mode 'cluster-type'
            { & $fx.Resolver -Scope canary -CatalogPath $fx.CatalogPath -ServiceConfigPath $fx.ConfigPath -QueriesDir $fx.QueriesDir } |
                Should -Throw -ExpectedMessage '*DRIFT_HALT:*BOGUS-01*shortName not in resolved cloud*'
        }

        It 'succeeds when -IgnoreDrift is passed' {
            $fx = New-TestFixture -InventoryResult $script:driftInv -Mode 'cluster-type'
            $r = & $fx.Resolver -Scope canary -CatalogPath $fx.CatalogPath -ServiceConfigPath $fx.ConfigPath -QueriesDir $fx.QueriesDir -IgnoreDrift
            @($r.resolved).pipelineKey | Should -Be @('SVC-SFMC')
            @($r.drift).Count | Should -Be 1
        }
    }

    Context 'static mode' {
        It 'returns all keys and never throws on drift' {
            $inv = [pscustomobject]@{
                scope  = 'canary'
                stamps = @()
                drift  = @([pscustomobject]@{ stampName = 'X'; reason = 'fake' })
                sources = [pscustomobject]@{}
            }
            $fx = New-TestFixture -InventoryResult $inv -Mode 'static'
            $r = & $fx.Resolver -Scope canary -CatalogPath $fx.CatalogPath -ServiceConfigPath $fx.ConfigPath -QueriesDir $fx.QueriesDir
            $r.mode | Should -Be 'static'
            @($r.resolved).pipelineKey | Sort-Object | Should -Be @('SVC-SFMC','SVC-SFRP')
            @($r.drift).Count | Should -Be 1   # informational, attached but not blocking
        }
    }

    Context 'cluster-type mode, empty live set' {
        It 'throws (refuses to silently trigger nothing or everything)' {
            $inv = [pscustomobject]@{
                scope   = 'canary'
                stamps  = @()
                drift   = @()
                sources = [pscustomobject]@{}
                kusto   = [pscustomobject]@{ ranAt = '2025-01-01T00:00:00Z'; durationMs = 1 }
            }
            $fx = New-TestFixture -InventoryResult $inv -Mode 'cluster-type'
            { & $fx.Resolver -Scope canary -CatalogPath $fx.CatalogPath -ServiceConfigPath $fx.ConfigPath -QueriesDir $fx.QueriesDir } |
                Should -Throw -ExpectedMessage '*0 cluster types from 0 stamp(s)*'
        }
    }
}
