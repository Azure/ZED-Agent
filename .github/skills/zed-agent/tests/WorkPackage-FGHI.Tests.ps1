<#
.SYNOPSIS
    Pester tests for Work Packages F/G/H/I — L-05, L-07, L-08, L-12, L-13,
    L-14, L-18, L-22, L-23, L-01, L-02.
#>

BeforeAll {
    $script:ScriptRoot      = Join-Path $PSScriptRoot '..' 'scripts'
    $script:TemplateRoot    = Join-Path $PSScriptRoot '..' 'templates'
    $script:ResolverPath    = Join-Path $script:ScriptRoot 'Resolve-TemplateParams.ps1'
    $script:AgentMdPath     = Join-Path $PSScriptRoot '..' '..' '..' 'agents' 'ZedAgent.agent.md'

    # --- Reusable catalog/config builders (same pattern as existing tests) ---
    function New-FGHICatalog {
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

    function New-FGHIServiceConfig {
        param(
            [array]$CanaryStamps = @(),
            [hashtable]$ProductionInventory = @{},
            [hashtable]$CcoaExclusions = @{},
            [hashtable]$Extra = @{}
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
        foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
        return $cfg
    }

    function Invoke-FGHIResolver {
        param(
            [hashtable]$Catalog,
            [hashtable]$ServiceConfig,
            [string]$Scope = 'canary',
            [string]$PipelineKey = 'TEST-PIPE',
            [string]$CurrentBranch = 'releases/M1',
            [switch]$DryRun,
            [switch]$Validate,
            [array]$AllPipelineResults = @(),
            [hashtable]$ExpectedSchema = @{}
        )
        $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) "fghi-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
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
        if ($DryRun)   { $params['DryRun']   = $true }
        if ($Validate) { $params['Validate'] = $true }
        if ($AllPipelineResults.Count -gt 0) { $params['AllPipelineResults'] = $AllPipelineResults }
        if ($ExpectedSchema.Count -gt 0)     { $params['ExpectedSchema']    = $ExpectedSchema }

        try {
            return & $script:ResolverPath @params
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# L-05: Validate mode catches bad tokens at resolve time
# ============================================================================
Describe 'L-05: Validate mode — stamp ID format check' {
    It 'throws VALIDATION_FAILED when stampNameStyle=short and a stamp lacks stampId' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
            # missing stampId — should fail validate
        )
        $catalog = New-FGHICatalog -Scope canary -RoutingMode cluster-type `
            -EntryOverrides @{ clusterType = 'sfmc'; stampNameStyle = 'short' }
        $cfg = New-FGHIServiceConfig -CanaryStamps $stamps

        { Invoke-FGHIResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary -Validate } |
            Should -Throw '*VALIDATION_FAILED*STAMP_ID_FORMAT*'
    }

    It 'passes validate when all stamps have stampId' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'ea'; clusterType = 'sfmc' }
        )
        $catalog = New-FGHICatalog -Scope canary -RoutingMode cluster-type `
            -EntryOverrides @{ clusterType = 'sfmc'; stampNameStyle = 'short' }
        $cfg = New-FGHIServiceConfig -CanaryStamps $stamps

        $result = Invoke-FGHIResolver -Catalog $catalog -ServiceConfig $cfg -Scope canary -Validate
        $result.validation.isValid | Should -BeTrue
    }
}

Describe 'L-05: Validate mode — wildcard region scope (L-09 re-check)' {
    It 'catches wildcard region value when resolved via token in production validate mode' {
        # The UNSAFE_REGION_SCOPE check fires on token-resolved values.
        # Use an inventory with regions set to * to trigger it.
        $prodStamps = @(
            @{ stampName = 'eus-prod1'; stampId = 'eus-01'; cloud = 'Public'; region = 'eastus' }
        )
        $catalog = New-FGHICatalog -Scope production -PipelineKey 'PROD-PIPE' `
            -TemplateParameters @{ 'PubStamps' = '{{pubStamps}}'; 'PubRegions' = '{{pubRegions}}' }
        # Override regions to provide a wildcard via the inventory regions field
        $cfg = New-FGHIServiceConfig -ProductionInventory @{
            Public = @{ stamps = $prodStamps; regions = @('*') }
        }
        { Invoke-FGHIResolver -Catalog $catalog -ServiceConfig $cfg `
            -Scope production -PipelineKey 'PROD-PIPE' -Validate } |
            Should -Throw '*UNSAFE_REGION_SCOPE*'
    }
}

Describe 'L-05: Validate mode — geography coverage gap (L-16)' {
    It 'reports missing expected regions across pipelines' {
        $stamps = @(
            @{ stampName = 'ea-can02-prot1'; stampId = 'ea-01'; cloud = 'Canary'; region = 'eastasia'; clusterType = 'sfmc' }
        )
        $priorResult = [PSCustomObject]@{
            templateParameters = @{ 'PubRegions' = 'eastasia' }
        }
        $catalog = New-FGHICatalog -Scope production -PipelineKey 'PROD-PIPE' `
            -TemplateParameters @{ 'PubStamps' = '{{pubStamps}}'; 'PubRegions' = '{{pubRegions}}' } `
            -RoutingMode cluster-type -EntryOverrides @{ clusterType = 'sfmc' }
        $cfg = New-FGHIServiceConfig -CanaryStamps $stamps `
            -ProductionInventory @{ Public = @{ stamps = $stamps } } `
            -Extra @{ expectedProductionRegions = @('eastasia','westeurope') }

        { Invoke-FGHIResolver -Catalog $catalog -ServiceConfig $cfg `
            -Scope production -PipelineKey 'PROD-PIPE' -Validate `
            -AllPipelineResults @($priorResult) } |
            Should -Throw '*GEOGRAPHY_COVERAGE_GAP*westeurope*'
    }
}

# ============================================================================
# L-07: Boolean flag confirmation
# ============================================================================
Describe 'L-07: Confirm-BooleanFlags detects conflicts across pipelines' {
    BeforeAll {
        $script:BoolFlagsPath = Join-Path $script:ScriptRoot 'Confirm-BooleanFlags.ps1'
    }

    It 'detects flag that differs between PROT and DT pipelines' {
        $baselines = @{
            'SVC-SFRP' = [PSCustomObject]@{
                templateParameters = [PSCustomObject]@{
                    CanaryScript = 'true'
                    MCScript     = 'false'
                }
            }
            'SVC-SFMC' = [PSCustomObject]@{
                templateParameters = [PSCustomObject]@{
                    CanaryScript = 'false'
                    MCScript     = 'false'
                }
            }
        }
        $result = & $script:BoolFlagsPath -PipelineBaselines $baselines -FlagNames @('CanaryScript','MCScript')
        $result.conflicts | Should -HaveCount 1
        $result.conflicts[0].flagName | Should -Be 'CanaryScript'
    }

    It 'returns no conflicts when all pipelines agree' {
        $baselines = @{
            'SVC-SFRP' = [PSCustomObject]@{
                templateParameters = [PSCustomObject]@{ MCScript = 'false' }
            }
            'SVC-SFMC' = [PSCustomObject]@{
                templateParameters = [PSCustomObject]@{ MCScript = 'false' }
            }
        }
        $result = & $script:BoolFlagsPath -PipelineBaselines $baselines -FlagNames @('MCScript')
        $result.conflicts | Should -HaveCount 0
    }

    It 'accepts owner decisions to resolve conflicts' {
        $baselines = @{
            'SVC-A' = [PSCustomObject]@{
                templateParameters = [PSCustomObject]@{ FFScript = 'true' }
            }
            'SVC-B' = [PSCustomObject]@{
                templateParameters = [PSCustomObject]@{ FFScript = 'false' }
            }
        }
        $result = & $script:BoolFlagsPath -PipelineBaselines $baselines `
            -FlagNames @('FFScript') -OwnerDecisions @{ FFScript = 'true' }
        $result.confirmed['FFScript'] | Should -Be 'true'
        $result.requiresConfirmation | Should -HaveCount 0
    }
}

# ============================================================================
# L-12: Invoke-BaselineFetch auto-fetches prior-run baseline
# ============================================================================
Describe 'L-12: Invoke-BaselineFetch fetches baselines per pipeline' {
    BeforeAll {
        $script:BaselineFetchPath = Join-Path $script:ScriptRoot 'Invoke-BaselineFetch.ps1'
    }

    It 'persists baseline JSON with per-pipeline data from callback' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l12-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $outputPath  = Join-Path $tmpDir 'baseline.json'

        @{
            production = @{
                'PROD-SFRP' = @{ id = 100; name = 'SFRP' }
                'PROD-SFMC' = @{ id = 200; name = 'SFMC' }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content $catalogPath -Encoding UTF8

        $callback = {
            param($PipelineId, $Top, $ResultFilter)
            @([PSCustomObject]@{
                runId              = 999
                runUrl             = 'https://dev.azure.com/org/proj/_build/results?buildId=999'
                finishedAt         = '2026-01-01T00:00:00Z'
                result             = 'succeeded'
                templateParameters = @{ PubRegions = 'eastus,westus' }
            })
        }

        $result = & $script:BaselineFetchPath -Organization 'TestOrg' -Project 'TestProj' `
            -PipelineCatalogPath $catalogPath -OutputPath $outputPath -FetchCallback $callback

        $result.pipelineCount | Should -Be 2
        Test-Path $outputPath | Should -BeTrue
        $persisted = Get-Content $outputPath -Raw | ConvertFrom-Json
        $persisted.pipelines.'PROD-SFRP'.latestRunId | Should -Be 999

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns empty baseline when no production pipelines exist' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l12e-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $outputPath  = Join-Path $tmpDir 'baseline.json'

        @{ production = @{} } | ConvertTo-Json -Depth 5 | Set-Content $catalogPath -Encoding UTF8

        $result = & $script:BaselineFetchPath -Organization 'TestOrg' -Project 'TestProj' `
            -PipelineCatalogPath $catalogPath -OutputPath $outputPath
        $result.pipelineCount | Should -Be 0

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# L-13: New-StampOnboarding computes parameter deltas
# ============================================================================
Describe 'L-13: New-StampOnboarding computes deltas for new stamps' {
    BeforeAll {
        $script:OnboardingPath = Join-Path $script:ScriptRoot 'New-StampOnboarding.ps1'
    }

    It 'routes SFRP stamp to the sfrp pipeline and excludes from sfmc' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l13-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $cfgPath     = Join-Path $tmpDir 'service-config.json'

        @{
            production = @{
                'PROD-SFRP' = @{ id = 100; clusterType = 'sfrp' }
                'PROD-SFMC' = @{ id = 200; clusterType = 'sfmc' }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content $catalogPath -Encoding UTF8
        @{ inventory = @{} } | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8

        $stamps = @(@{ prefix = 'uac'; region = 'uaecentral'; pipelineType = 'SFRP'; cloud = 'Public' })
        $result = & $script:OnboardingPath -NewStamps $stamps `
            -ServiceConfigPath $cfgPath -PipelineCatalogPath $catalogPath

        $result.deltas['PROD-SFRP'].addToRegions | Should -Contain 'uaecentral'
        $result.deltas['PROD-SFMC'].addToExcludeStamps | Should -Contain 'uac'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws on missing required stamp fields' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l13v-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $cfgPath     = Join-Path $tmpDir 'service-config.json'

        @{ production = @{ 'P1' = @{ id = 1; clusterType = 'sfrp' } } } |
            ConvertTo-Json -Depth 5 | Set-Content $catalogPath -Encoding UTF8
        @{ inventory = @{} } | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8

        { & $script:OnboardingPath -NewStamps @(@{ prefix = 'uac' }) `
            -ServiceConfigPath $cfgPath -PipelineCatalogPath $catalogPath } |
            Should -Throw '*NEW_STAMP_MISSING_FIELD*'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# L-14: Resolve-StampPrefix
# ============================================================================
Describe 'L-14: Resolve-StampPrefix resolves prefix to region or throws' {
    BeforeAll {
        $script:StampPrefixPath = Join-Path $script:ScriptRoot 'Resolve-StampPrefix.ps1'
    }

    It 'resolves a known prefix from stampPrefixToRegion map' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l14-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $cfgPath = Join-Path $tmpDir 'service-config.json'
        @{
            stampPrefixToRegion = @{
                uac = 'uaecentral'
                ilc = 'israelcentral'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8

        $result = & $script:StampPrefixPath -StampPrefix 'uac' -ServiceConfigPath $cfgPath
        $result | Should -Be 'uaecentral'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws UNKNOWN_STAMP_PREFIX on unrecognized prefix' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l14u-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $cfgPath = Join-Path $tmpDir 'service-config.json'
        @{
            stampPrefixToRegion = @{ uac = 'uaecentral' }
        } | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8

        { & $script:StampPrefixPath -StampPrefix 'xyz' -ServiceConfigPath $cfgPath } |
            Should -Throw '*UNKNOWN_STAMP_PREFIX*'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws when stampPrefixToRegion is absent from config' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l14m-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $cfgPath = Join-Path $tmpDir 'service-config.json'
        @{ service = @{ name = 'TestSvc' } } | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8

        { & $script:StampPrefixPath -StampPrefix 'uac' -ServiceConfigPath $cfgPath } |
            Should -Throw '*UNKNOWN_STAMP_PREFIX*stampPrefixToRegion*'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# L-18: Release comms templates include route/geography scope
# ============================================================================
Describe 'L-18: Templates state route/geography scope' {
    It 'production-triggered-message.html contains routeCount and geographyCount' {
        $html = Get-Content (Join-Path $script:TemplateRoot 'production-triggered-message.html') -Raw
        $html | Should -Match '\{\{routeCount\}\}'
        $html | Should -Match '\{\{geographyCount\}\}'
        $html | Should -Match '\{\{regionListHtml\}\}'
    }

    It 'canary-approval-request.html contains scope tokens' {
        $html = Get-Content (Join-Path $script:TemplateRoot 'canary-approval-request.html') -Raw
        $html | Should -Match '\{\{routeCount\}\}'
        $html | Should -Match '\{\{geographyCount\}\}'
    }

    It 'approval-needed-message.html contains scope tokens' {
        $html = Get-Content (Join-Path $script:TemplateRoot 'approval-needed-message.html') -Raw
        $html | Should -Match '\{\{routeCount\}\}'
        $html | Should -Match '\{\{geographyCount\}\}'
    }

    It 'ev2-stage-progress-email.html contains scope and stage-map tokens' {
        $html = Get-Content (Join-Path $script:TemplateRoot 'ev2-stage-progress-email.html') -Raw
        $html | Should -Match '\{\{routeCount\}\}'
        $html | Should -Match '\{\{stageMapName\}\}'
        $html | Should -Match '\{\{stageMapVersion\}\}'
    }
}

# ============================================================================
# L-22: Resolve-StageMap persists stage-map metadata
# ============================================================================
Describe 'L-22: Resolve-StageMap persists stageMapName/stageMapVersion' {
    BeforeAll {
        $script:StageMapPath = Join-Path $script:ScriptRoot 'Resolve-StageMap.ps1'
    }

    It 'returns verified status when introspection + definition are provided' {
        $introspection = [PSCustomObject]@{
            stageMapName    = 'DefaultStageMap'
            stageMapVersion = '2.1'
        }
        $definition = @{
            eastus  = 'Stage1'
            westus  = 'Stage2'
        }
        $result = & $script:StageMapPath -IntrospectionResult $introspection `
            -SelectedRegions @('eastus','westus') -StageMapDefinition $definition `
            -PipelineKey 'PROD-SFRP'

        $result.stageMapName    | Should -Be 'DefaultStageMap'
        $result.stageMapVersion | Should -Be '2.1'
        $result.status          | Should -Be 'verified'
        $result.isVerified      | Should -BeTrue
        $result.regionStageMapping['eastus'] | Should -Be 'Stage1'
    }

    It 'returns unverified when no stage-map definition is available' {
        $introspection = [PSCustomObject]@{
            stageMapName    = 'DefaultStageMap'
            stageMapVersion = '2.1'
        }
        $result = & $script:StageMapPath -IntrospectionResult $introspection `
            -PipelineKey 'PROD-SFRP'

        $result.status     | Should -Be 'unverified'
        $result.isVerified | Should -BeFalse
    }

    It 'returns unverified when introspection has no stageMapName' {
        $introspection = [PSCustomObject]@{ otherField = 'x' }
        $result = & $script:StageMapPath -IntrospectionResult $introspection `
            -PipelineKey 'PROD-SFRP'

        $result.stageMapName | Should -BeNullOrEmpty
        $result.status       | Should -Be 'unverified'
    }

    It 'returns partially-verified when some regions are unmapped' {
        $introspection = [PSCustomObject]@{
            stageMapName    = 'SM'
            stageMapVersion = '1.0'
        }
        $definition = @{ eastus = 'Stage1' }
        $result = & $script:StageMapPath -IntrospectionResult $introspection `
            -SelectedRegions @('eastus','uksouth') -StageMapDefinition $definition `
            -PipelineKey 'PROD-SFRP'

        $result.status          | Should -Be 'partially-verified'
        $result.unmappedRegions | Should -Contain 'uksouth'
    }
}

# ============================================================================
# L-23: Reporting rules in ZedAgent.agent.md
# ============================================================================
Describe 'L-23: Investigation reporting discipline in agent spec' {
    It 'ZedAgent.agent.md contains INVESTIGATION REPORTING DISCIPLINE rule' {
        $md = Get-Content $script:AgentMdPath -Raw
        $md | Should -Match 'INVESTIGATION REPORTING DISCIPLINE'
    }

    It 'requires leading with verified facts' {
        $md = Get-Content $script:AgentMdPath -Raw
        $md | Should -Match 'Lead with verified facts'
    }

    It 'requires labeling unverified items with [UNVERIFIED] or [HYPOTHESIS]' {
        $md = Get-Content $script:AgentMdPath -Raw
        $md | Should -Match '\[UNVERIFIED\]'
        $md | Should -Match '\[HYPOTHESIS\]'
    }

    It 'requires time-boxing log scans' {
        $md = Get-Content $script:AgentMdPath -Raw
        $md | Should -Match '3-minute time-box'
    }

    It 'requires explicit INVESTIGATION INCOMPLETE block' {
        $md = Get-Content $script:AgentMdPath -Raw
        $md | Should -Match 'INVESTIGATION INCOMPLETE'
    }
}

# ============================================================================
# L-01: Save-TeamsConversationId persists IDs in secrets.json
# ============================================================================
Describe 'L-01: Save-TeamsConversationId persists conversation IDs' {
    BeforeAll {
        $script:SaveConvPath = Join-Path $script:ScriptRoot 'Save-TeamsConversationId.ps1'
    }

    It 'creates new secrets.json with conversation entry' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l01-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $secretsPath = Join-Path $tmpDir 'secrets.json'

        $result = & $script:SaveConvPath -ConversationId '19:abc@thread.v2' `
            -ConversationLabel 'release-channel' -SecretsJsonPath $secretsPath

        $result.success | Should -BeTrue
        $result.conversationId | Should -Be '19:abc@thread.v2'
        Test-Path $secretsPath | Should -BeTrue

        $persisted = Get-Content $secretsPath -Raw | ConvertFrom-Json
        $persisted.teamsConversations.'release-channel'.conversationId | Should -Be '19:abc@thread.v2'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'appends to existing secrets.json without overwriting' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l01a-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $secretsPath = Join-Path $tmpDir 'secrets.json'
        @{ existingKey = 'existingValue' } | ConvertTo-Json | Set-Content $secretsPath -Encoding UTF8

        & $script:SaveConvPath -ConversationId '19:xyz@thread.v2' `
            -ConversationLabel 'approvals' -SecretsJsonPath $secretsPath | Out-Null

        $persisted = Get-Content $secretsPath -Raw | ConvertFrom-Json
        $persisted.existingKey | Should -Be 'existingValue'
        $persisted.teamsConversations.approvals.conversationId | Should -Be '19:xyz@thread.v2'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws on whitespace-only conversation ID' {
        { & $script:SaveConvPath -ConversationId '   ' `
            -ConversationLabel 'test' -SecretsJsonPath 'dummy.json' } |
            Should -Throw '*TEAMS_EMPTY_CONVERSATION_ID*'
    }
}

# ============================================================================
# L-08: Invoke-Rebuild regenerates derived config
# ============================================================================
Describe 'L-08: Invoke-Rebuild handles rebuild workflow' {
    BeforeAll {
        $script:RebuildPath = Join-Path $script:ScriptRoot 'Invoke-Rebuild.ps1'
    }

    It 'updates release.json with new build info from callback' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l08-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $releaseJsonPath = Join-Path $tmpDir 'release.json'

        @{
            canary = @{
                'CAN-SFRP' = @{ id = 50; name = 'Canary SFRP' }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content $catalogPath -Encoding UTF8
        @{ releaseId = 'R1'; buildId = 100; buildNumber = 'old-build' } |
            ConvertTo-Json | Set-Content $releaseJsonPath -Encoding UTF8

        $queueCallback = {
            param($Organization, $Project, $PipelineId, $Branch)
            [PSCustomObject]@{ buildId = 999; buildNumber = '20260101.1' }
        }

        $result = & $script:RebuildPath -ReleaseId 'R1' -ReleaseBranch 'releases/M1' `
            -Organization 'TestOrg' -Project 'TestProj' -OfficialBuildPipelineId 1 `
            -PipelineCatalogPath $catalogPath -ReleaseJsonPath $releaseJsonPath `
            -QueueBuildCallback $queueCallback

        $result.newBuildId     | Should -Be 999
        $result.newBuildNumber | Should -Be '20260101.1'
        $result.releaseJsonUpdated | Should -BeTrue

        $updatedRelease = Get-Content $releaseJsonPath -Raw | ConvertFrom-Json
        $updatedRelease.buildId | Should -Be 999

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws when no QueueBuildCallback is provided' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l08n-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $releaseJsonPath = Join-Path $tmpDir 'release.json'

        @{ canary = @{} } | ConvertTo-Json | Set-Content $catalogPath -Encoding UTF8
        @{ releaseId = 'R1' } | ConvertTo-Json | Set-Content $releaseJsonPath -Encoding UTF8

        { & $script:RebuildPath -ReleaseId 'R1' -ReleaseBranch 'releases/M1' `
            -Organization 'O' -Project 'P' -OfficialBuildPipelineId 1 `
            -PipelineCatalogPath $catalogPath -ReleaseJsonPath $releaseJsonPath } |
            Should -Throw '*REBUILD_NO_CALLBACK*'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws on unknown retrigger pipeline key' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "l08u-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $catalogPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $releaseJsonPath = Join-Path $tmpDir 'release.json'

        @{ canary = @{ 'CAN-A' = @{ id = 1; name = 'A' } } } |
            ConvertTo-Json -Depth 5 | Set-Content $catalogPath -Encoding UTF8
        @{ releaseId = 'R1' } | ConvertTo-Json | Set-Content $releaseJsonPath -Encoding UTF8

        $queueCallback = {
            param($Organization, $Project, $PipelineId, $Branch)
            [PSCustomObject]@{ buildId = 1; buildNumber = '1.0' }
        }

        { & $script:RebuildPath -ReleaseId 'R1' -ReleaseBranch 'releases/M1' `
            -Organization 'O' -Project 'P' -OfficialBuildPipelineId 1 `
            -PipelineCatalogPath $catalogPath -ReleaseJsonPath $releaseJsonPath `
            -RetriggerPipelineKeys @('NONEXISTENT') -QueueBuildCallback $queueCallback } |
            Should -Throw '*REBUILD_UNKNOWN_PIPELINE*'

        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# L-02: Register-WatcherTask sets MultipleInstances = StopExisting
# ============================================================================
Describe 'L-02: Register-WatcherTask watcher concurrency guard' {
    It 'Register-ReleaseWatcherTask function uses StopExisting with fallback' {
        $content = Get-Content (Join-Path $script:ScriptRoot 'Register-WatcherTask.ps1') -Raw
        $content | Should -Match 'MultipleInstances'
        $content | Should -Match 'StopExisting'
        # Fallback to IgnoreNew when StopExisting is not supported
        $content | Should -Match 'IgnoreNew'
    }
}
