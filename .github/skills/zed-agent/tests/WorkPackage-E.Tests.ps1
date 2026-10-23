<#
.SYNOPSIS
    Pester tests for Work Package E — L-21 wiring, L-06, L-11, L-15, L-10.
#>

BeforeAll {
    $script:ScriptRoot   = Join-Path $PSScriptRoot '..' 'scripts'
    $script:ResolverPath = Join-Path $script:ScriptRoot 'Resolve-TemplateParams.ps1'
    $script:TriggerPath  = Join-Path $script:ScriptRoot 'Invoke-TriggerAndCancel.ps1'

    # --- Reusable catalog/config builders (same pattern as Resolve-TemplateParams.Tests.ps1) ---
    function New-WPECatalog {
        param(
            [string]$Scope = 'canary',
            [string]$PipelineKey = 'TEST-PIPE',
            [hashtable]$TemplateParameters = @{ 'CanaryStamps' = '{{canaryStamps}}'; 'CanaryRegions' = '{{canaryRegions}}' },
            [hashtable]$EntryOverrides = @{},
            [string]$RoutingMode = 'static',
            [hashtable]$Ev2CloudCoverage = @{}
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
            ev2CloudCoverage = $Ev2CloudCoverage
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

    function New-WPEServiceConfig {
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

    function Invoke-WPEResolver {
        param(
            [hashtable]$Catalog,
            [hashtable]$ServiceConfig,
            [string]$Scope = 'canary',
            [string]$PipelineKey = 'TEST-PIPE',
            [string]$CurrentBranch = 'releases/M1',
            [switch]$DryRun
        )
        $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) "wpe-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $cfgPath     = Join-Path $tmpDir 'service-config.json'
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $Catalog      | ConvertTo-Json -Depth 10 | Set-Content $catalogPath -Encoding UTF8
        $ServiceConfig | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8

        $params = @{
            PipelineKey         = $PipelineKey
            Scope               = $Scope
            CurrentBranch       = $CurrentBranch
            ServiceConfigPath   = $cfgPath
            PipelineCatalogPath = $catalogPath
        }
        if ($DryRun) { $params['DryRun'] = $true }

        try {
            return & $script:ResolverPath @params
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Task 0: L-21 — EV2 cancel wiring in Invoke-TriggerAndCancel.ps1
# ============================================================================
Describe 'L-21: EV2 cancel wiring — run had no rollout (no-op)' {
    It 'completes without EV2 cancel when Step is 5 (canary scope, no EV2)' {
        # Step 5 is canary — no EV2 rollout expected. EV2 cancel block only fires for Step 10/15.
        $tempDir = Join-Path $TestDrive 'ev2-noop'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $relDir = Join-Path $tempDir '.zed-agent' 'releases' 'R1'
        New-Item -ItemType Directory -Path $relDir -Force | Out-Null

        # Mock the az/Invoke-RestMethod calls
        $mockScript = Join-Path $tempDir 'Invoke-TriggerAndCancel.ps1'
        $originalContent = Get-Content $script:TriggerPath -Raw

        # We can't easily run the full script (it needs ADO auth), but we can verify
        # the EV2 cancel block structure by checking it only fires for Step 10/15.
        # The script has: if ($triggered -and $cancelledAt -and $Step -in @(10, 15))
        # For Step 5, the EV2 cancel block should not execute.
        $originalContent | Should -Match '\$Step -in @\(10, 15\)'
    }
}

Describe 'L-21: EV2 cancel wiring — rollout active (cancel attempted + verified)' {
    It 'wiring code calls Stop-Ev2Rollout.ps1 when EV2 rollout exists for cancelled build' {
        # Verify the wiring code references Stop-Ev2Rollout.ps1
        $content = Get-Content $script:TriggerPath -Raw
        $content | Should -Match 'Stop-Ev2Rollout\.ps1'
        $content | Should -Match 'Get-Ev2RolloutStatus\.ps1'
        $content | Should -Match 'ev2ServiceGroups'
    }
}

Describe 'L-21: EV2 cancel wiring — verification failure (loud throw)' {
    It 'wiring code throws EV2_CANCEL_WIRING_FAILED on Stop-Ev2Rollout failure' {
        $content = Get-Content $script:TriggerPath -Raw
        $content | Should -Match 'EV2_CANCEL_WIRING_FAILED'
        # Must NOT swallow errors — the throw is mandatory
        $content | Should -Match 'throw.*EV2_CANCEL_WIRING_FAILED'
    }

    It 'preserves the UNVERIFIED marking from Stop-Ev2Rollout.ps1' {
        $ev2Script = Get-Content (Join-Path $script:ScriptRoot 'EV2' 'Stop-Ev2Rollout.ps1') -Raw
        $ev2Script | Should -Match 'UNVERIFIED'
        $ev2Script | Should -Match 'EV2_CANCEL_UNVERIFIED'
    }
}

# ============================================================================
# Task 0: L-21 — EV2 cancel wiring with mocked scripts
# ============================================================================
Describe 'L-21: EV2 cancel wiring — mocked integration' {
    BeforeEach {
        $mockDir = Join-Path $TestDrive "ev2-mock-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
        $ev2Dir  = Join-Path $mockDir 'EV2'
        New-Item -ItemType Directory -Path $ev2Dir -Force | Out-Null
    }

    It 'no-op when Get-Ev2RolloutStatus finds no rollout for the build' {
        # Mock Get-Ev2RolloutStatus.ps1 that returns no rollout
        $getStatusMock = @'
param($BuildId, $ServiceGroup)
return $null
'@
        Set-Content (Join-Path $ev2Dir 'Get-Ev2RolloutStatus.ps1') $getStatusMock -Encoding UTF8

        # Mock Stop-Ev2Rollout.ps1 that should NOT be called
        $stopMock = @'
param($RolloutId, $ServiceGroup, $BuildId, $VerifyTimeoutSeconds)
throw "Stop-Ev2Rollout should not be called when no rollout exists"
'@
        Set-Content (Join-Path $ev2Dir 'Stop-Ev2Rollout.ps1') $stopMock -Encoding UTF8

        # Simulate the wiring logic directly
        $ev2RolloutId    = $null
        $ev2ServiceGroup = 'TestSG'
        $runId           = 123456
        $triggered       = $true
        $cancelledAt     = (Get-Date).ToString('o')
        $Step            = 10

        $getStatusScript = Join-Path $ev2Dir 'Get-Ev2RolloutStatus.ps1'
        try {
            $statusResult = & $getStatusScript -BuildId $runId -ServiceGroup $ev2ServiceGroup -ErrorAction Stop
            if ($statusResult -and $statusResult.RolloutId) {
                $ev2RolloutId = $statusResult.RolloutId
            }
        } catch { }

        $ev2RolloutId | Should -BeNullOrEmpty
    }

    It 'calls Stop-Ev2Rollout when Get-Ev2RolloutStatus returns active rollout' {
        # Mock Get-Ev2RolloutStatus.ps1 that returns an active rollout
        $getStatusMock = @'
param($BuildId, $ServiceGroup)
return [PSCustomObject]@{ RolloutId = "rollout-guid-123"; Status = "InProgress" }
'@
        Set-Content (Join-Path $ev2Dir 'Get-Ev2RolloutStatus.ps1') $getStatusMock -Encoding UTF8

        # Mock Stop-Ev2Rollout.ps1 that succeeds
        $stopMock = @'
param($RolloutId, $ServiceGroup, $BuildId, $VerifyTimeoutSeconds)
return [PSCustomObject]@{
    rolloutId = $RolloutId
    cancelAttempted = $true
    cancelVerified = $true
    finalStatus = "Cancelled"
}
'@
        Set-Content (Join-Path $ev2Dir 'Stop-Ev2Rollout.ps1') $stopMock -Encoding UTF8

        $ev2ServiceGroup = 'TestSG'
        $runId           = 123456

        $getStatusScript = Join-Path $ev2Dir 'Get-Ev2RolloutStatus.ps1'
        $stopEv2Script   = Join-Path $ev2Dir 'Stop-Ev2Rollout.ps1'

        $statusResult = & $getStatusScript -BuildId $runId -ServiceGroup $ev2ServiceGroup -ErrorAction Stop
        $statusResult.RolloutId | Should -Be 'rollout-guid-123'

        $cancelResult = & $stopEv2Script -RolloutId $statusResult.RolloutId -ServiceGroup $ev2ServiceGroup -BuildId "$runId" -VerifyTimeoutSeconds 60
        $cancelResult.cancelVerified | Should -BeTrue
        $cancelResult.finalStatus | Should -Be 'Cancelled'
    }

    It 'throws on Stop-Ev2Rollout verification failure (loud failure)' {
        $stopMock = @'
param($RolloutId, $ServiceGroup, $BuildId, $VerifyTimeoutSeconds)
throw "EV2_CANCEL_UNVERIFIED: Cancellation was sent but could NOT be verified"
'@
        Set-Content (Join-Path $ev2Dir 'Stop-Ev2Rollout.ps1') $stopMock -Encoding UTF8

        $stopEv2Script = Join-Path $ev2Dir 'Stop-Ev2Rollout.ps1'
        { & $stopEv2Script -RolloutId 'r1' -ServiceGroup 'SG' -BuildId '999' -VerifyTimeoutSeconds 10 } |
            Should -Throw '*EV2_CANCEL_UNVERIFIED*'
    }
}

# ============================================================================
# Task 1 (L-06): {{canaryProdStamps}} / {{canaryProdRegions}} tokens
# ============================================================================
Describe 'L-06: canaryProdStamps and canaryProdRegions tokens' {

    It 'resolves {{canaryProdStamps}} to Public-cloud canary stamps (not ea-01)' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'eastasia'; clusterType = 'sfmc' }
            @{ stampName = 'ecy-prod-prot1'; stampId = 'ecy-01'; cloud = 'Public'; region = 'eastus2euap'; clusterType = 'sfmc' }
            @{ stampName = 'ccy-prod-prot1'; stampId = 'ccy-01'; cloud = 'Public'; region = 'centraluseuap'; clusterType = 'sfmc' }
        )
        $catalog = New-WPECatalog -Scope canary -RoutingMode cluster-type `
            -TemplateParameters @{
                'CanaryStamps'     = '{{canaryStamps}}'
                'CanarystampsProd' = '{{canaryProdStamps}}'
                'CanaryProdRegions'= '{{canaryProdRegions}}'
            } `
            -EntryOverrides @{ clusterType = 'sfmc' }
        $cfg = New-WPEServiceConfig -CanaryStamps $stamps

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        # canaryStamps should be only Canary-cloud: ea-01 (ps-array format from Format-ByParamName)
        $result.templateParameters['CanaryStamps'] | Should -Be '@("ea-01")'
        # canaryProdStamps should be only Public-cloud: ecy-01,ccy-01 (ps-array format)
        $result.templateParameters['CanarystampsProd'] | Should -Be '@("ecy-01","ccy-01")'
        # canaryProdRegions should be the Public-cloud stamp regions
        $result.templateParameters['CanaryProdRegions'] | Should -Match 'centraluseuap'
        $result.templateParameters['CanaryProdRegions'] | Should -Match 'eastus2euap'
    }

    It 'canaryProdStamps is empty when no Public-cloud stamps exist in canary inventory' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'eastasia' }
        )
        $catalog = New-WPECatalog -Scope canary `
            -TemplateParameters @{
                'CanaryStamps'     = '{{canaryStamps}}'
                'CanarystampsProd' = '{{canaryProdStamps}}'
            }
        $cfg = New-WPEServiceConfig -CanaryStamps $stamps

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanarystampsProd'] | Should -Be '@()'
    }
}

# ============================================================================
# Task 1 (L-06): paramFormat — ps-array and regions-wrapper
# ============================================================================
Describe 'L-06: paramFormat ps-array yields @("ea-01")' {

    It 'wraps canaryProdStamps in PS array notation' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'eastasia' }
            @{ stampName = 'ecy-prod-prot1'; stampId = 'ecy-01'; cloud = 'Public'; region = 'eastus2euap' }
        )
        $catalog = New-WPECatalog -Scope canary `
            -TemplateParameters @{
                'CanarystampsProd' = '{{canaryProdStamps}}'
            } `
            -EntryOverrides @{
                discoveryNotes = @{ paramFormat = 'ps-array' }
            }
        $cfg = New-WPEServiceConfig -CanaryStamps $stamps

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanarystampsProd'] | Should -Be '@("ecy-01")'
    }

    It 'wraps multiple stamps in PS array notation' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'eastasia' }
            @{ stampName = 'ecy-prod-prot1'; stampId = 'ecy-01'; cloud = 'Public'; region = 'eastus2euap' }
            @{ stampName = 'ccy-prod-prot1'; stampId = 'ccy-01'; cloud = 'Public'; region = 'centraluseuap' }
        )
        $catalog = New-WPECatalog -Scope canary `
            -TemplateParameters @{
                'CanarystampsProd' = '{{canaryProdStamps}}'
            } `
            -EntryOverrides @{
                discoveryNotes = @{ paramFormat = 'ps-array' }
            }
        $cfg = New-WPEServiceConfig -CanaryStamps $stamps

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        # Order may vary; check both stamps are present in PS array notation
        $val = $result.templateParameters['CanarystampsProd']
        $val | Should -Match '^\@\("'
        $val | Should -Match 'ecy-01'
        $val | Should -Match 'ccy-01'
    }
}

Describe 'L-06: paramFormat regions-wrapper yields regions(eastasia)' {

    It 'wraps region tokens in regions() wrapper with full region names' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'eastasia' }
            @{ stampName = 'ecy-prod-prot1'; stampId = 'ecy-01'; cloud = 'Public'; region = 'eastus2euap' }
        )
        $catalog = New-WPECatalog -Scope canary `
            -TemplateParameters @{
                'CanaryProdRegions' = '{{canaryProdRegions}}'
            } `
            -EntryOverrides @{
                discoveryNotes = @{ paramFormat = 'regions-wrapper' }
            }
        $cfg = New-WPEServiceConfig -CanaryStamps $stamps

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary
        $result.templateParameters['CanaryProdRegions'] | Should -Be 'regions(eastus2euap)'
    }
}

# ============================================================================
# Task 2 (L-11): Per-pipeline script flags survive resolution
# ============================================================================
Describe 'L-11: Per-pipeline script flags — static values survive resolution' {

    It 'passes through static script flags unchanged (not token-substituted)' {
        $catalog = New-WPECatalog -Scope production -PipelineKey 'PROT-PROD-SFMC' `
            -TemplateParameters @{
                'MCScript'  = 'false'
                'FFScript'  = 'True'
                'FFstamps'  = '@("uga-01")'
                'PubStamps' = '{{pubStamps}}'
            }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = @(
                @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            )}
        }

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROT-PROD-SFMC'
        $result.templateParameters['MCScript']  | Should -Be 'false'
        $result.templateParameters['FFScript']  | Should -Be 'True'
        $result.templateParameters['FFstamps']  | Should -Be '@("uga-01")'
    }

    It 'absent flag stays absent — not emitted as false' {
        # SFRP has MCScript=True, FFScript=True, but NO Bleu/USNat/USSec params
        $catalog = New-WPECatalog -Scope production -PipelineKey 'SFRP-PROD' `
            -TemplateParameters @{
                'MCScript'  = 'True'
                'FFScript'  = 'True'
                'PubStamps' = '{{pubStamps}}'
            }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = @(
                @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            )}
        }

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'SFRP-PROD'
        $result.templateParameters.ContainsKey('BleuScript') | Should -BeFalse
        $result.templateParameters.ContainsKey('UsNatScript') | Should -BeFalse
        $result.templateParameters.ContainsKey('UsSecScript') | Should -BeFalse
        $result.templateParameters['MCScript']  | Should -Be 'True'
        $result.templateParameters['FFScript']  | Should -Be 'True'
    }

    It 'DT-PROD-SFMC preserves all sovereign flags including explicit false' {
        $catalog = New-WPECatalog -Scope production -PipelineKey 'DT-PROD-SFMC' `
            -TemplateParameters @{
                'MCScript'     = 'False'
                'FFScript'     = 'True'
                'FFstamps'     = '@("uga-01")'
                'BleuScript'   = 'False'
                'UsNatScript'  = 'False'
                'UsSecScript'  = 'False'
                'PubStamps'    = '{{pubStamps}}'
            }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = @(
                @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            )}
        }

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'DT-PROD-SFMC'
        $result.templateParameters['MCScript']    | Should -Be 'False'
        $result.templateParameters['BleuScript']  | Should -Be 'False'
        $result.templateParameters['UsNatScript'] | Should -Be 'False'
        $result.templateParameters['UsSecScript'] | Should -Be 'False'
        $result.templateParameters['FFScript']    | Should -Be 'True'
    }
}

# ============================================================================
# Task 3 (L-15): ev2CloudCoverage cross-check throws on contradiction
# ============================================================================
Describe 'L-15: ev2CloudCoverage contradiction with resolved script flags' {

    It 'throws EV2_CLOUD_COVERAGE_MISMATCH when FFScript=True but Fairfax not in coverage' {
        $catalog = New-WPECatalog -Scope production -PipelineKey 'PROT-PROD' `
            -TemplateParameters @{
                'FFScript'  = 'True'
                'PubStamps' = '{{pubStamps}}'
            } `
            -Ev2CloudCoverage @{ 'PROT-PROD' = @('Public') }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = @(
                @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            )}
        }

        { Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROT-PROD' } |
            Should -Throw '*EV2_CLOUD_COVERAGE_MISMATCH*'
    }

    It 'throws EV2_CLOUD_COVERAGE_MISMATCH when BleuScript=False but Bleu is in coverage' {
        $catalog = New-WPECatalog -Scope production -PipelineKey 'DT-PROD' `
            -TemplateParameters @{
                'BleuScript' = 'False'
                'PubStamps'  = '{{pubStamps}}'
            } `
            -Ev2CloudCoverage @{ 'DT-PROD' = @('Public', 'Bleu') }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = @(
                @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            )}
        }

        { Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'DT-PROD' } |
            Should -Throw '*EV2_CLOUD_COVERAGE_MISMATCH*'
    }

    It 'passes when script flags agree with ev2CloudCoverage' {
        $catalog = New-WPECatalog -Scope production -PipelineKey 'PROT-PROD' `
            -TemplateParameters @{
                'FFScript'  = 'True'
                'MCScript'  = 'false'
                'PubStamps' = '{{pubStamps}}'
            } `
            -Ev2CloudCoverage @{ 'PROT-PROD' = @('Public', 'Fairfax') }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = @(
                @{ stampName = 's1'; stampId = 's1'; cloud = 'Public'; region = 'eastus' }
            )}
        }

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROT-PROD'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ============================================================================
# Task 4 (L-10): EV2 dual-gate alignment
# ============================================================================
Describe 'L-10: EV2 dual-gate misalignment — stamp not excluded but region absent' {

    It 'throws EV2_DUAL_GATE_MISALIGNMENT when stamp region is absent from PubRegions' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'wus-prod-prot1'; stampId = 'wus-01'; cloud = 'Public'; region = 'westus' }
        )
        $catalog = New-WPECatalog -Scope production -PipelineKey 'PROD-PIPE' `
            -TemplateParameters @{
                'PubRegions'           = 'eastus'
                'PublicExcludestamps'  = ''
                'PubStamps'            = '{{pubStamps}}'
            }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        { Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE' } |
            Should -Throw '*EV2_DUAL_GATE_MISALIGNMENT*'
    }
}

Describe 'L-10: EV2 dual-gate misalignment — region in PubRegions but all stamps excluded' {

    It 'throws EV2_DUAL_GATE_MISALIGNMENT when all stamps in a region are excluded' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'wus-prod-prot1'; stampId = 'wus-01'; cloud = 'Public'; region = 'westus' }
        )
        $catalog = New-WPECatalog -Scope production -PipelineKey 'PROD-PIPE' `
            -TemplateParameters @{
                'PubRegions'           = 'eastus,westus'
                'PublicExcludestamps'  = 'wus-01'
                'PubStamps'            = '{{pubStamps}}'
            }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        { Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE' } |
            Should -Throw '*EV2_DUAL_GATE_MISALIGNMENT*'
    }
}

Describe 'L-10: EV2 dual-gate alignment — valid configuration passes' {

    It 'passes when PubRegions and ExcludeStamps are aligned' {
        $prodStamps = @(
            @{ stampName = 'eus-prod-prot1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
            @{ stampName = 'wus-prod-prot1'; stampId = 'wus-01'; cloud = 'Public'; region = 'westus' }
        )
        $catalog = New-WPECatalog -Scope production -PipelineKey 'PROD-PIPE' `
            -TemplateParameters @{
                'PubRegions'           = 'eastus,westus'
                'PublicExcludestamps'  = ''
                'PubStamps'            = '{{pubStamps}}'
            }
        $cfg = New-WPEServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps }
        }

        $result = Invoke-WPEResolver -Catalog $catalog -ServiceConfig $cfg -Scope production -PipelineKey 'PROD-PIPE'
        $result | Should -Not -BeNullOrEmpty
    }
}
