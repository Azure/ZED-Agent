<#
.SYNOPSIS
    Pester tests for Resolve-TemplateParams.ps1 — covers L-04, L-03, U-07, L-09, U-06 fixes.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Resolve-TemplateParams.ps1'

    # --- Minimal catalog builder ---
    function New-MinimalCatalog {
        param(
            [string]$Scope = 'canary',
            [string]$PipelineKey = 'TEST-PIPE',
            [hashtable]$TemplateParameters = @{ 'CanaryStamps' = '{{canaryStamps}}'; 'CanaryRegions' = '{{canaryRegions}}' },
            [hashtable]$EntryOverrides = @{},
            [string]$RoutingMode = 'static'
        )
        $entry = @{
            name = 'Test Pipeline'
            id   = 12345
            sourceBranch = 'refs/heads/{{currentBranch}}'
            templateParameters = $TemplateParameters
        }
        foreach ($k in $EntryOverrides.Keys) { $entry[$k] = $EntryOverrides[$k] }

        $catalog = @{
            officialBuild    = @{ name = 'OB'; id = 1; sourceBranch = 'refs/heads/main'; templateParameters = @{} }
            ev2ServiceGroups = @{}
            ev2CloudCoverage = @{}
        }
        $routingObj = @{ mode = $RoutingMode }
        if ($Scope -eq 'canary') {
            $catalog['canary']        = @{ $PipelineKey = $entry }
            $catalog['production']    = @{}
            $catalog['canaryRouting'] = $routingObj
        } else {
            $catalog['canary']            = @{}
            $catalog['production']        = @{ $PipelineKey = $entry }
            $catalog['productionRouting'] = $routingObj
        }
        return $catalog
    }

    # --- Minimal service-config builder ---
    function New-MinimalServiceConfig {
        param(
            [array]$CanaryStamps = @(),
            [hashtable]$ProductionInventory = @{},
            [hashtable]$CcoaExclusions = @{}
        )
        $cfg = @{
            inventory = @{
                canary = @{ stamps = $CanaryStamps }
            }
        }
        if ($ProductionInventory.Count -gt 0) {
            $cfg.inventory['production'] = $ProductionInventory
        }
        if ($CcoaExclusions.Count -gt 0) {
            $cfg.inventory['ccoaExclusions'] = $CcoaExclusions
        }
        return $cfg
    }

    function Invoke-Resolver {
        param(
            [hashtable]$Catalog,
            [hashtable]$ServiceConfig,
            [string]$Scope = 'canary',
            [string]$PipelineKey = 'TEST-PIPE',
            [string]$CurrentBranch = 'releases/M1',
            [switch]$DryRun,
            [switch]$TestMode
        )
        $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) "rtp-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $cfgPath     = Join-Path $tmpDir 'service-config.json'
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $Catalog      | ConvertTo-Json -Depth 10 | Set-Content $catalogPath -Encoding UTF8
        $ServiceConfig | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8

        $params = @{
            PipelineKey        = $PipelineKey
            Scope              = $Scope
            CurrentBranch      = $CurrentBranch
            ServiceConfigPath  = $cfgPath
            PipelineCatalogPath = $catalogPath
        }
        if ($DryRun)    { $params['DryRun']    = $true }
        if ($TestMode)  { $params['TestMode']  = $true }

        try {
            $result = & $script:ScriptPath @params
            return $result
        }
        finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- ArtifactsBranch test-mode helpers ---
    function New-ArtifactsBranchCatalog {
        param([string]$Scope = 'canary', [string]$PipelineKey = 'TEST-PIPE', [string]$RepoName = 'MyRepo', [string]$BaseBranch = 'develop')
        $entry = @{
            name = 'Test Pipeline'
            id   = 99
            sourceBranch = 'refs/heads/develop'
            templateParameters = @{
                'ArtifactsBranch' = '{{currentBranch}}'
                'CanaryStamps'    = '{{canaryStamps}}'
            }
        }
        $catalog = @{
            officialBuild    = @{ name = 'OB'; id = 1; sourceBranch = 'refs/heads/main'; templateParameters = @{} }
            ev2ServiceGroups = @{}
            ev2CloudCoverage = @{}
            yamlRepos        = @{ $RepoName = @{ baseBranch = $BaseBranch } }
        }
        $routingObj = @{ mode = 'static' }
        if ($Scope -eq 'canary') {
            $catalog['canary']        = @{ $PipelineKey = $entry }
            $catalog['production']    = @{}
            $catalog['canaryRouting'] = $routingObj
        } else {
            $entry.templateParameters = @{ 'ArtifactsBranch' = '{{currentBranch}}'; 'PubStamps' = '{{pubStamps}}' }
            $catalog['canary']            = @{}
            $catalog['production']        = @{ $PipelineKey = $entry }
            $catalog['productionRouting'] = $routingObj
        }
        return $catalog
    }

    function New-ServiceConfigWithRepo {
        param([string]$RepoName = 'MyRepo')
        $cfg = New-MinimalServiceConfig -CanaryStamps @(
            @{ stampName = 'ea-can-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea' }
        )
        $cfg['ado'] = @{ repository = $RepoName }
        return $cfg
    }
}

# ============================================================================
# L-04: Cloud filter in Get-FilteredStamps
# ============================================================================
Describe 'L-04: Cloud filter in Get-FilteredStamps' {

    It 'keeps ea-01 (cloud=Canary) and drops ecy-01/ccy-01 (cloud=Public) for Canary scope' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
            @{ stampName = 'ecy-prod-prot1'; stampId = 'ecy-01'; cloud = 'Public'; region = 'ecy'; clusterType = 'sfmc' }
            @{ stampName = 'ccy-prod-prot1'; stampId = 'ccy-01'; cloud = 'Public'; region = 'ccy'; clusterType = 'sfmc' }
        )
        $catalog = New-MinimalCatalog -Scope canary -RoutingMode cluster-type -EntryOverrides @{ clusterType = 'sfmc' }
        $cfg = New-MinimalServiceConfig -CanaryStamps $stamps

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanaryStamps'] | Should -Be '@("ea-01")'
    }

    It 'keeps stamps with no cloud property (absent = in-scope)' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
            @{ stampName = 'xx-can02-prot1'; stampId = 'xx-01'; region = 'xx'; clusterType = 'sfmc' }  # no cloud property
        )
        $catalog = New-MinimalCatalog -Scope canary -RoutingMode cluster-type -EntryOverrides @{ clusterType = 'sfmc' }
        $cfg = New-MinimalServiceConfig -CanaryStamps $stamps

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanaryStamps'] | Should -Be '@("ea-01","xx-01")'
    }

    It 'applies cloud filter for production stamps too' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'eus-can-prot1';  stampId = 'eus-c1'; cloud = 'Canary'; region = 'eastus' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'; 'PubRegions' = '{{pubRegions}}'
        }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result.templateParameters['PubStamps'] | Should -Be '@("eus-01")'
    }
}

# ============================================================================
Describe 'L-03: stampId preferred over stampName (canary)' {

    It 'uses stampId when present and stampNameStyle is short (default)' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
        )
        $catalog = New-MinimalCatalog -Scope canary -RoutingMode cluster-type -EntryOverrides @{ clusterType = 'sfmc' }
        $cfg = New-MinimalServiceConfig -CanaryStamps $stamps

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanaryStamps'] | Should -Be '@("ea-01")'
    }

    It 'falls back to stampName when stampId is absent' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
        )
        $catalog = New-MinimalCatalog -Scope canary -RoutingMode cluster-type -EntryOverrides @{ clusterType = 'sfmc' }
        $cfg = New-MinimalServiceConfig -CanaryStamps $stamps

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanaryStamps'] | Should -Be '@("ea-can02-prot1")'
    }

    It 'uses stampName when stampNameStyle is full' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
        )
        $catalog = New-MinimalCatalog -Scope canary -RoutingMode cluster-type -EntryOverrides @{
            clusterType = 'sfmc'
            stampNameStyle = 'full'
        }
        $cfg = New-MinimalServiceConfig -CanaryStamps $stamps

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanaryStamps'] | Should -Be '@("ea-can02-prot1")'
    }
}

Describe 'U-07: stampId preferred over stampName (production)' {

    It 'uses stampId for production stamps when stampNameStyle is short' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'wus-prod-prot1'; stampId = 'wus-01'; cloud = 'Public'; region = 'westus' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'
        }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result.templateParameters['PubStamps'] | Should -Be '@("eus-01","wus-01")'
    }
}

# ============================================================================
# L-09: CCOA exclusions and fail-closed guards
# ============================================================================
Describe 'L-09: CCOA exclusions' {

    It 'excludeStamps populated from CCOA exclusions' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'isc-prod-prot1'; stampId = 'isc-01'; cloud = 'Public'; region = 'indiasouthcentral' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'; 'ExcludeStamps' = '{{excludeStamps}}'
        }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        } -CcoaExclusions @{ stamps = @('isc-01'); regions = @('indiasouthcentral') }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result.templateParameters['ExcludeStamps'] | Should -Be '@("isc-01")'
        $result.templateParameters['PubStamps']     | Should -Be '@("eus-01")'
    }

    It 'subtracts CCOA-excluded regions from emitted region tokens' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'isc-prod-prot1'; stampId = 'isc-01'; cloud = 'Public'; region = 'indiasouthcentral' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'; 'PubRegions' = '{{pubRegions}}'
        }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        } -CcoaExclusions @{ stamps = @('isc-01'); regions = @('indiasouthcentral') }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result.templateParameters['PubRegions'] | Should -Be 'regions(eastus)'
    }

    It 'works with empty CCOA exclusions (backward compat)' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'
        }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result.templateParameters['PubStamps'] | Should -Be '@("eus-01")'
    }
}

Describe 'L-09: Fail-closed guard — wildcard region' {

    It 'throws UNSAFE_REGION_SCOPE on wildcard regions(*)' {
        # This test creates a production inventory with regions set to a wildcard
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubRegions' = '{{pubRegions}}'
        }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ regions = @('regions(*)'); stamps = @( @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'regions(*)' } ) }
        }

        { Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE' } |
            Should -Throw '*UNSAFE_REGION_SCOPE*'
    }
}

Describe 'L-09: Fail-closed guard — maxRegions exceeded' {

    It 'throws when resolved region count exceeds maxRegions' {
        $prodStamps = @(
            @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 's2'; stampId = 's2'; cloud = 'Public'; region = 'westus' }
            @{ stampName = 's3'; stampId = 's3'; cloud = 'Public'; region = 'northeurope' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubRegions' = '{{pubRegions}}'
        } -EntryOverrides @{ maxRegions = 2 }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        { Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE' } |
            Should -Throw '*UNSAFE_REGION_SCOPE*maxRegions*'
    }

    It 'passes when region count is within maxRegions' {
        $prodStamps = @(
            @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 's2'; stampId = 's2'; cloud = 'Public'; region = 'westus' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubRegions' = '{{pubRegions}}'
        } -EntryOverrides @{ maxRegions = 5 }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result | Should -Not -BeNullOrEmpty
    }
}

Describe 'L-09: Fail-closed guard — requiresExclusions' {

    It 'throws MISSING_EXCLUSIONS when requiresExclusions=true but no exclusions configured' {
        $prodStamps = @(
            @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'
        } -EntryOverrides @{ requiresExclusions = $true }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        { Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE' } |
            Should -Throw '*MISSING_EXCLUSIONS*'
    }

    It 'passes when requiresExclusions=true and exclusions are present' {
        $prodStamps = @(
            @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 's2'; stampId = 's2'; cloud = 'Public'; region = 'westus' }
        )
        $catalog = New-MinimalCatalog -Scope production -PipelineKey 'PROD-PIPE' -TemplateParameters @{
            'PubStamps' = '{{pubStamps}}'
        } -EntryOverrides @{ requiresExclusions = $true }
        $cfg = New-MinimalServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        } -CcoaExclusions @{ stamps = @('s2') }

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result.templateParameters['PubStamps'] | Should -Be '@("s1")'
    }
}

# ============================================================================
# U-06: sdpType override
# ============================================================================
Describe 'U-06: sdpType override from catalog entry' {

    It 'defaults to Standard when sdpType not specified on entry' {
        $catalog = New-MinimalCatalog -Scope canary -TemplateParameters @{ 'SdpType' = '{{sdpType}}' }
        $cfg = New-MinimalServiceConfig -CanaryStamps @(
            @{ stampName = 'ea-can02-prot1'; cloud = 'Canary'; region = 'ea' }
        )

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['SdpType'] | Should -Be 'Standard'
    }

    It 'uses sdpType from catalog entry when specified' {
        $catalog = New-MinimalCatalog -Scope canary -TemplateParameters @{ 'SdpType' = '{{sdpType}}' } -EntryOverrides @{ sdpType = 'Standard' }
        $cfg = New-MinimalServiceConfig -CanaryStamps @(
            @{ stampName = 'ea-can02-prot1'; cloud = 'Canary'; region = 'ea' }
        )

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['SdpType'] | Should -Be 'Standard'
    }

    It 'uses Test for sdpType when DryRun regardless of catalog entry' {
        $catalog = New-MinimalCatalog -Scope canary -TemplateParameters @{ 'SdpType' = '{{sdpType}}' } -EntryOverrides @{ sdpType = 'Standard' }
        $cfg = New-MinimalServiceConfig -CanaryStamps @(
            @{ stampName = 'ea-can02-prot1'; cloud = 'Canary'; region = 'ea' }
        )

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary -DryRun
        $result.templateParameters['SdpType'] | Should -Be 'Test'
    }
}

# ============================================================================
# ArtifactsBranch test-mode override
# ============================================================================
Describe 'ArtifactsBranch: test-mode resolves to baseBranch, production resolves to currentBranch' {

    It 'test mode: ArtifactsBranch resolves to baseBranch (not currentBranch)' {
        $catalog = New-ArtifactsBranchCatalog -RepoName 'MyRepo' -BaseBranch 'develop'
        $cfg     = New-ServiceConfigWithRepo -RepoName 'MyRepo'

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary `
            -CurrentBranch 'zedforge/test-20260825-1500' -TestMode
        $result.templateParameters['ArtifactsBranch'] | Should -Be 'develop'
    }

    It 'production mode: ArtifactsBranch still resolves to currentBranch (unaffected)' {
        $catalog = New-ArtifactsBranchCatalog -RepoName 'MyRepo' -BaseBranch 'develop'
        $cfg     = New-ServiceConfigWithRepo -RepoName 'MyRepo'

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary `
            -CurrentBranch 'releases/2026-09'
        $result.templateParameters['ArtifactsBranch'] | Should -Be 'releases/2026-09'
    }

    It 'test mode: uses baseBranch from catalog, not a hardcoded value' {
        $catalog = New-ArtifactsBranchCatalog -RepoName 'MyRepo' -BaseBranch 'main'
        $cfg     = New-ServiceConfigWithRepo -RepoName 'MyRepo'

        $result = Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary `
            -CurrentBranch 'zedforge/test-20260825-1600' -TestMode
        $result.templateParameters['ArtifactsBranch'] | Should -Be 'main'
    }

    It 'test mode: throws when yamlRepos block is missing' {
        $catalog = New-ArtifactsBranchCatalog -RepoName 'MyRepo' -BaseBranch 'develop'
        # Remove yamlRepos to simulate missing block
        $catalog.Remove('yamlRepos')
        $cfg = New-ServiceConfigWithRepo -RepoName 'MyRepo'

        { Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary `
            -CurrentBranch 'zedforge/test-20260825-1700' -TestMode } |
            Should -Throw "*yamlRepos*"
    }

    It 'test mode: throws when ado.repository is missing from service-config' {
        $catalog = New-ArtifactsBranchCatalog -RepoName 'MyRepo' -BaseBranch 'develop'
        # Build service config WITHOUT ado.repository
        $cfg = New-MinimalServiceConfig -CanaryStamps @(
            @{ stampName = 'ea-can-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea' }
        )
        # No ado.repository field

        { Invoke-Resolver -Catalog $catalog -ServiceConfig $cfg -Scope canary `
            -CurrentBranch 'zedforge/test-20260825-1800' -TestMode } |
            Should -Throw "*ado.repository*"
    }
}
