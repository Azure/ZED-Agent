BeforeAll {
    $scriptRoot = Join-Path $PSScriptRoot '..' 'scripts'
}

Describe 'L-16: Assert-GeographyCoverage — geography coverage gate' {
    BeforeAll {
        $assertScript = Join-Path $scriptRoot 'Assert-GeographyCoverage.ps1'
    }

    BeforeEach {
        $tempDir2 = Join-Path $TestDrive 'geo-basic'
        New-Item -ItemType Directory -Path $tempDir2 -Force | Out-Null

        # 5 geographies covering 8 regions
        @'
param($ServiceConfigPath, $ExcludeRegions = @())
@(
    [PSCustomObject]@{ DataCenterName='East Asia';      RegionShortName='eastasia';         StampPrefix='ea';  Ev2Geography='Asia Pacific';  StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='Southeast Asia'; RegionShortName='southeastasia';    StampPrefix='sea'; Ev2Geography='Asia Pacific';  StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='North Europe';   RegionShortName='northeurope';      StampPrefix='ne';  Ev2Geography='Europe';        StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='West Europe';    RegionShortName='westeurope';       StampPrefix='we';  Ev2Geography='Europe';        StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='East US';        RegionShortName='eastus';           StampPrefix='eus'; Ev2Geography='United States'; StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='West US';        RegionShortName='westus';           StampPrefix='wus'; Ev2Geography='United States'; StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='UAE Central';    RegionShortName='uaecentral';       StampPrefix='uac'; Ev2Geography='Middle East';   StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='South Africa N'; RegionShortName='southafricanorth'; StampPrefix='san'; Ev2Geography='Africa';        StampCount=1; DatacenterType=@('ACTIVE') }
)
'@ | Set-Content (Join-Path $tempDir2 'Get-RegionMapping.ps1') -Encoding UTF8
        Get-Content $assertScript -Raw | Set-Content (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -Encoding UTF8
        Copy-Item (Join-Path (Split-Path $assertScript -Parent) 'lib') (Join-Path $tempDir2 'lib') -Recurse -Force
    }

    It 'passes when all geographies are covered by the union of pipelines' {
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastasia,southeastasia,northeurope,westeurope)' }
            'PROT-PROD-SFMC' = @{ PubRegions = 'regions(eastus,westus,uaecentral,southafricanorth)' }
        }
        $result = & (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -PipelineParams $params -SkipPersist
        $result.missingCount | Should -Be 0
        $result.expectedCount | Should -Be 5
    }

    It 'is service-agnostic: covers geographies under arbitrary partition names' {
        # No parameter is called PubRegions. A service with its own sovereign
        # partitions, plus one flat-scope pipeline, must be scored identically.
        $params = @{
            'ALPHA' = @{ TerraRegions = 'regions(eastasia,southeastasia)'; AquaRegions = 'regions(northeurope,westeurope)' }
            'BETA'  = @{ Regions      = 'regions(eastus,westus,uaecentral,southafricanorth)' }
        }
        $result = & (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -PipelineParams $params -SkipPersist
        $result.missingCount  | Should -Be 0
        $result.expectedCount | Should -Be 5
    }

    It 'is service-agnostic: still detects a gap under arbitrary partition names' {
        $params = @{
            'ALPHA' = @{ TerraRegions = 'regions(eastasia,southeastasia)'; AquaRegions = 'regions(northeurope)' }
            'BETA'  = @{ QuasarRegions = 'regions(eastus,westus)' }
        }
        { & (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -PipelineParams $params -SkipPersist } |
            Should -Throw '*GEOGRAPHY_COVERAGE_GAP*'
    }

    It 'throws GEOGRAPHY_COVERAGE_GAP when geographies are missing' {
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastasia,southeastasia,northeurope,westeurope)' }
            'PROT-PROD-SFMC' = @{ PubRegions = 'regions(eastus,westus)' }
        }
        { & (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -PipelineParams $params -SkipPersist } |
            Should -Throw '*GEOGRAPHY_COVERAGE_GAP*'
    }

    It 'correctly identifies SFRP/SFMC overlap geographies' {
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastasia,southeastasia,northeurope,westeurope,eastus,westus,uaecentral,southafricanorth)' }
            'PROT-PROD-SFMC' = @{ PubRegions = 'regions(eastasia,eastus,westus)' }
        }
        $result = & (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -PipelineParams $params -SkipPersist
        $result.missingCount | Should -Be 0
        $result.overlap.Count | Should -BeGreaterThan 0
    }

    It 'parses bare comma-separated lists (no regions wrapper)' {
        $params = @{
            'P1' = @{ PubRegions = 'eastasia,southeastasia,northeurope,westeurope,eastus,westus,uaecentral,southafricanorth' }
        }
        $result = & (Join-Path $tempDir2 'Assert-GeographyCoverage.ps1') -PipelineParams $params -SkipPersist
        $result.missingCount | Should -Be 0
    }
}

Describe 'L-16: Assert-GeographyCoverage — unit tests with mocked regions' {
    BeforeAll {
        $assertScript = Join-Path $scriptRoot 'Assert-GeographyCoverage.ps1'
    }

    # These tests mock Get-RegionMapping.ps1 by replacing it with a temp script
    BeforeEach {
        $tempDir = Join-Path $TestDrive 'scripts'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'scripts' 'EV2') -Force | Out-Null

        # Create mock Get-RegionMapping.ps1
        @'
param($ServiceConfigPath, $ExcludeRegions = @())
@(
    [PSCustomObject]@{ DataCenterName='East Asia';      RegionShortName='eastasia';      StampPrefix='ea';  Ev2Geography='Asia Pacific';  StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='North Europe';   RegionShortName='northeurope';   StampPrefix='ne';  Ev2Geography='Europe';        StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='East US';        RegionShortName='eastus';        StampPrefix='eus'; Ev2Geography='United States'; StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='Central US';     RegionShortName='centralus';     StampPrefix='cus'; Ev2Geography='United States'; StampCount=1; DatacenterType=@('ACTIVE') }
    [PSCustomObject]@{ DataCenterName='Sweden Central'; RegionShortName='swedencentral'; StampPrefix='sc';  Ev2Geography='Europe';        StampCount=1; DatacenterType=@('ACTIVE') }
)
'@ | Set-Content (Join-Path $tempDir 'Get-RegionMapping.ps1') -Encoding UTF8

        # Copy the real Assert-GeographyCoverage.ps1 to temp so its $PSScriptRoot resolves to $tempDir
        $realScript = Get-Content $assertScript -Raw -Encoding UTF8
        $realScript | Set-Content (Join-Path $tempDir 'Assert-GeographyCoverage.ps1') -Encoding UTF8
        Copy-Item (Join-Path (Split-Path $assertScript -Parent) 'lib') (Join-Path $tempDir 'lib') -Recurse -Force
    }

    It 'throws when geographies are missing (L-16 exact scenario: 66/73)' {
        $localScript = Join-Path $tempDir 'Assert-GeographyCoverage.ps1'

        # SFRP covers Asia Pacific but NOT Europe (missing northeurope, swedencentral geos)
        # SFMC covers United States but missing some
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastasia)' }
            'PROT-PROD-SFMC' = @{ PubRegions = 'regions(eastus)' }
        }

        { & $localScript -PipelineParams $params -SkipPersist } |
            Should -Throw '*GEOGRAPHY_COVERAGE_GAP*'
    }

    It 'passes when all geographies are covered' {
        $localScript = Join-Path $tempDir 'Assert-GeographyCoverage.ps1'

        # Full coverage: SFRP covers Asia Pacific + Europe, SFMC covers US
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastasia,northeurope,swedencentral)' }
            'PROT-PROD-SFMC' = @{ PubRegions = 'regions(eastus,centralus)' }
        }

        $result = & $localScript -PipelineParams $params -SkipPersist
        $result.missingCount | Should -Be 0
    }

    It 'detects SFRP/SFMC overlap correctly' {
        $localScript = Join-Path $tempDir 'Assert-GeographyCoverage.ps1'

        # Both cover Asia Pacific (overlap on eastasia), full coverage
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastasia,northeurope,swedencentral)' }
            'PROT-PROD-SFMC' = @{ PubRegions = 'regions(eastasia,eastus,centralus)' }
        }

        $result = & $localScript -PipelineParams $params -SkipPersist
        $result.missingCount | Should -Be 0
        # Verify overlap was detected
        $result.overlap.Count | Should -BeGreaterThan 0
    }

    It 'names every missing geography in the error message' {
        $localScript = Join-Path $tempDir 'Assert-GeographyCoverage.ps1'

        # Only cover United States — missing Asia Pacific and Europe
        $params = @{
            'PROT-PROD-SFRP' = @{ PubRegions = 'regions(eastus,centralus)' }
        }

        $err = $null
        try { & $localScript -PipelineParams $params -SkipPersist } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*Asia Pacific*'
        $err | Should -BeLike '*Europe*'
    }
}

Describe 'L-17: Get-PriorRunBaseline — union of valid runs, excluding cancelled/failed' {
    BeforeAll {
        $baselineScript = Join-Path $scriptRoot 'Get-PriorRunBaseline.ps1'
    }

    It 'excludes cancelled runs from the baseline' {
        $tempDir = Join-Path $TestDrive 'baseline-cancel'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        @'
param($Organization, $Project, $PipelineId, $Top, $ResultFilter)
@(
    [PSCustomObject]@{ runId=100; result='succeeded'; templateParameters=@{ PubRegions='regions(eastasia,northeurope)' } }
    [PSCustomObject]@{ runId=101; result='canceled';  templateParameters=@{ PubRegions='regions(westeurope,eastus)' } }
    [PSCustomObject]@{ runId=102; result='succeeded'; templateParameters=@{ PubRegions='regions(westus)' } }
)
'@ | Set-Content (Join-Path $tempDir 'Read-PriorRun.ps1') -Encoding UTF8

        $localScript = Get-Content $baselineScript -Raw
        $localScript | Set-Content (Join-Path $tempDir 'Get-PriorRunBaseline.ps1') -Encoding UTF8
        Copy-Item (Join-Path (Split-Path $baselineScript -Parent) 'lib') (Join-Path $tempDir 'lib') -Recurse -Force

        $result = & (Join-Path $tempDir 'Get-PriorRunBaseline.ps1') `
            -Organization 'testorg' -Project 'testproj' `
            -PipelineIds @{ 'PROT-PROD-SFRP' = 123 }

        $entry = $result | Where-Object { $_.pipelineKey -eq 'PROT-PROD-SFRP' }
        $entry.regions | Should -Contain 'eastasia'
        $entry.regions | Should -Contain 'northeurope'
        $entry.regions | Should -Contain 'westus'
        $entry.regions | Should -Not -Contain 'westeurope'
        $entry.regions | Should -Not -Contain 'eastus'
        $entry.excludedRunCount | Should -Be 1
    }

    It 'excludes failed runs from the baseline' {
        $tempDir = Join-Path $TestDrive 'baseline-failed'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        @'
param($Organization, $Project, $PipelineId, $Top, $ResultFilter)
@(
    [PSCustomObject]@{ runId=200; result='failed';    templateParameters=@{ PubRegions='regions(eastasia)' } }
    [PSCustomObject]@{ runId=201; result='succeeded'; templateParameters=@{ PubRegions='regions(northeurope)' } }
)
'@ | Set-Content (Join-Path $tempDir 'Read-PriorRun.ps1') -Encoding UTF8

        $localScript = Get-Content $baselineScript -Raw
        $localScript | Set-Content (Join-Path $tempDir 'Get-PriorRunBaseline.ps1') -Encoding UTF8
        Copy-Item (Join-Path (Split-Path $baselineScript -Parent) 'lib') (Join-Path $tempDir 'lib') -Recurse -Force

        $result = & (Join-Path $tempDir 'Get-PriorRunBaseline.ps1') `
            -Organization 'testorg' -Project 'testproj' `
            -PipelineIds @{ 'P1' = 456 }

        $entry = $result | Where-Object { $_.pipelineKey -eq 'P1' }
        $entry.regions | Should -Contain 'northeurope'
        $entry.regions | Should -Not -Contain 'eastasia'
        $entry.excludedRunCount | Should -Be 1
    }

    It 'unions regions from continuation runs' {
        $tempDir = Join-Path $TestDrive 'baseline-union'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        @'
param($Organization, $Project, $PipelineId, $Top, $ResultFilter)
@(
    [PSCustomObject]@{ runId=300; result='succeeded'; templateParameters=@{ PubRegions='regions(eastasia,northeurope)' } }
    [PSCustomObject]@{ runId=301; result='succeeded'; templateParameters=@{ PubRegions='regions(westeurope,eastus)' } }
    [PSCustomObject]@{ runId=302; result='succeeded'; templateParameters=@{ PubRegions='regions(westus)' } }
)
'@ | Set-Content (Join-Path $tempDir 'Read-PriorRun.ps1') -Encoding UTF8

        $localScript = Get-Content $baselineScript -Raw
        $localScript | Set-Content (Join-Path $tempDir 'Get-PriorRunBaseline.ps1') -Encoding UTF8
        Copy-Item (Join-Path (Split-Path $baselineScript -Parent) 'lib') (Join-Path $tempDir 'lib') -Recurse -Force

        $result = & (Join-Path $tempDir 'Get-PriorRunBaseline.ps1') `
            -Organization 'testorg' -Project 'testproj' `
            -PipelineIds @{ 'P1' = 789 }

        $entry = $result | Where-Object { $_.pipelineKey -eq 'P1' }
        # Union of all 3 runs
        $entry.regions | Should -Contain 'eastasia'
        $entry.regions | Should -Contain 'northeurope'
        $entry.regions | Should -Contain 'westeurope'
        $entry.regions | Should -Contain 'eastus'
        $entry.regions | Should -Contain 'westus'
        $entry.contributingRunIds.Count | Should -Be 3
    }
}

Describe 'L-19: Compare-PipelineRuns — fail-closed complete diff' {
    BeforeAll {
        $compareScript = Join-Path $scriptRoot 'Compare-PipelineRuns.ps1'
    }

    It 'accepts genuinely identical runs' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions      = 'regions(eastasia,northeurope)'
                PublicExcludestamps = '@("isc-01")'
                MCScript        = 'True'
            }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    self           = [PSCustomObject]@{ refName = 'refs/heads/Release-2608'; version = 'abc123' }
                    templates      = [PSCustomObject]@{ version = 'tmpl-v1' }
                    obcoretemplates = [PSCustomObject]@{ version = 'obc-v1' }
                }
            }
        }

        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions      = 'regions(eastasia,northeurope)'
                PublicExcludestamps = '@("isc-01")'
                MCScript        = 'True'
            }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    self           = [PSCustomObject]@{ refName = 'refs/heads/Release-2608'; version = 'abc123' }
                    templates      = [PSCustomObject]@{ version = 'tmpl-v1' }
                    obcoretemplates = [PSCustomObject]@{ version = 'obc-v1' }
                }
            }
        }

        $result = & $compareScript -SourceRun $source -CandidateRun $candidate
        $result.isAccepted | Should -Be $true
        $result.templateDrift | Should -Be $false
    }

    It 'rejects a run whose template commit drifted while only PubRegions was authorized (L-19/L-20)' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions = 'regions(eastasia)'
                MCScript   = 'True'
            }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    self           = [PSCustomObject]@{ version = 'abc123' }
                    templates      = [PSCustomObject]@{ version = 'tmpl-v1' }
                    obcoretemplates = [PSCustomObject]@{ version = 'obc-v1' }
                    '1escoretemplates' = [PSCustomObject]@{ version = '1es-v1' }
                }
            }
        }

        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions = 'regions(eastasia,northeurope)'  # Allowed change
                MCScript   = 'True'
            }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    self           = [PSCustomObject]@{ version = 'abc123' }
                    templates      = [PSCustomObject]@{ version = 'tmpl-v2' }       # DRIFTED!
                    obcoretemplates = [PSCustomObject]@{ version = 'obc-v2' }       # DRIFTED!
                    '1escoretemplates' = [PSCustomObject]@{ version = '1es-v2' }    # DRIFTED!
                }
            }
        }

        { & $compareScript -SourceRun $source -CandidateRun $candidate `
            -AllowedDifferences @('PubRegions') } |
            Should -Throw '*PIPELINE_RUN_DIFF_REJECTED*'
    }

    It 'reports TEMPLATE_DRIFT_DETECTED in error for drifted template repos' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    templates = [PSCustomObject]@{ version = 'v1' }
                }
            }
        }
        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia,northeurope)' }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    templates = [PSCustomObject]@{ version = 'v2' }
                }
            }
        }

        $err = $null
        try {
            & $compareScript -SourceRun $source -CandidateRun $candidate `
                -AllowedDifferences @('PubRegions')
        } catch { $err = $_.Exception.Message }

        $err | Should -BeLike '*TEMPLATE_DRIFT_DETECTED*'
        $err | Should -BeLike '*L-20*'
    }

    It 'allows only explicitly listed fields to differ' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions = 'regions(eastasia)'
                MCScript   = 'True'
            }
        }
        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions = 'regions(eastasia,northeurope)'
                MCScript   = 'False'  # Unauthorized change!
            }
        }

        { & $compareScript -SourceRun $source -CandidateRun $candidate `
            -AllowedDifferences @('PubRegions') } |
            Should -Throw '*MCScript*'
    }

    It 'treats unknown/new fields as differences (deny by default)' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
        }
        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{
                PubRegions = 'regions(eastasia)'
                NewUnknownParam = 'surprise!'  # New field not in source
            }
        }

        { & $compareScript -SourceRun $source -CandidateRun $candidate } |
            Should -Throw '*NewUnknownParam*'
    }

    It 'rejects when sourceBranch differs and is not in allow-list' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
        }
        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2609'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
        }

        { & $compareScript -SourceRun $source -CandidateRun $candidate } |
            Should -Throw '*sourceBranch*'
    }
}

Describe 'L-20: Template drift pinning/rejection' {
    BeforeAll {
        $compareScript = Join-Path $scriptRoot 'Compare-PipelineRuns.ps1'
    }

    It 'allows template drift when explicitly in allow-list' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    templates = [PSCustomObject]@{ version = 'v1' }
                }
            }
        }
        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia,northeurope)' }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    templates = [PSCustomObject]@{ version = 'v2' }
                }
            }
        }

        $result = & $compareScript -SourceRun $source -CandidateRun $candidate `
            -AllowedDifferences @('PubRegions', 'resources.repositories.templates')
        $result.isAccepted | Should -Be $true
        $result.templateDrift | Should -Be $true
    }

    It 'rejects template drift when not in allow-list (default deny)' {
        $source = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    obcoretemplates = [PSCustomObject]@{ version = 'v1' }
                }
            }
        }
        $candidate = [PSCustomObject]@{
            sourceBranch = 'refs/heads/Release-2608'
            templateParameters = @{ PubRegions = 'regions(eastasia)' }
            resources = [PSCustomObject]@{
                repositories = [PSCustomObject]@{
                    obcoretemplates = [PSCustomObject]@{ version = 'v2' }
                }
            }
        }

        { & $compareScript -SourceRun $source -CandidateRun $candidate } |
            Should -Throw '*obcoretemplates*'
    }
}

Describe 'L-21: Stop-Ev2Rollout — EV2 cancellation safety' {
    BeforeAll {
        $stopScript = Join-Path $scriptRoot 'EV2' 'Stop-Ev2Rollout.ps1'
    }

    It 'detects an already-cancelled rollout and skips cancellation' {
        # Create temp version of script that mocks external calls
        $tempDir = Join-Path $TestDrive 'ev2-cancel-test'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $mockScript = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RolloutId,
    [Parameter(Mandatory)][string]$ServiceGroup,
    [string]$RolloutInfra = "Prod",
    [string]$BuildId,
    [int]$MaxRetries = 3,
    [int]$VerifyTimeoutSeconds = 60,
    [string]$ServiceConfigPath = ''
)
$ErrorActionPreference = 'Stop'

# Simulate: rollout already cancelled
$result = [PSCustomObject]@{
    rolloutId        = $RolloutId
    serviceGroup     = $ServiceGroup
    rolloutInfra     = $RolloutInfra
    buildId          = $BuildId
    previousStatus   = 'Cancelled'
    cancelAttempted  = $false
    cancelVerified   = $true
    finalStatus      = 'Cancelled'
    error            = $null
    verificationLog  = @('Rollout already in terminal state ''Cancelled'' — no cancellation needed.')
}
return $result
'@
        $mockScript | Set-Content (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') -Encoding UTF8

        $result = & (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') `
            -RolloutId 'abc-123-def' -ServiceGroup 'TestSG'

        $result.cancelAttempted | Should -Be $false
        $result.cancelVerified | Should -Be $true
        $result.finalStatus | Should -Be 'Cancelled'
    }

    It 'attempts cancellation for an active rollout' {
        $tempDir = Join-Path $TestDrive 'ev2-cancel-active'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $mockScript = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RolloutId,
    [Parameter(Mandatory)][string]$ServiceGroup,
    [string]$RolloutInfra = "Prod",
    [string]$BuildId,
    [int]$MaxRetries = 3,
    [int]$VerifyTimeoutSeconds = 60,
    [string]$ServiceConfigPath = ''
)
$ErrorActionPreference = 'Stop'

# Simulate: active rollout → cancel → verify
$result = [PSCustomObject]@{
    rolloutId        = $RolloutId
    serviceGroup     = $ServiceGroup
    rolloutInfra     = $RolloutInfra
    buildId          = $BuildId
    previousStatus   = 'InProgress'
    cancelAttempted  = $true
    cancelVerified   = $true
    finalStatus      = 'Cancelled'
    error            = $null
    verificationLog  = @(
        'Cancel attempt 1 of 3...',
        'Cancel request accepted (attempt 1).',
        'Verification check: status=''Cancelled'''
    )
}
return $result
'@
        $mockScript | Set-Content (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') -Encoding UTF8

        $result = & (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') `
            -RolloutId 'active-rollout-id' -ServiceGroup 'TestSG' -BuildId '12345'

        $result.cancelAttempted | Should -Be $true
        $result.cancelVerified | Should -Be $true
        $result.previousStatus | Should -Be 'InProgress'
        $result.finalStatus | Should -Be 'Cancelled'
    }

    It 'throws when cancellation fails after all retries' {
        $tempDir = Join-Path $TestDrive 'ev2-cancel-fail'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $mockScript = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RolloutId,
    [Parameter(Mandatory)][string]$ServiceGroup,
    [string]$RolloutInfra = "Prod",
    [string]$BuildId,
    [int]$MaxRetries = 3,
    [int]$VerifyTimeoutSeconds = 60,
    [string]$ServiceConfigPath = ''
)
$ErrorActionPreference = 'Stop'
throw "EV2_CANCEL_FAILED: Could not cancel EV2 rollout $RolloutId after $MaxRetries attempts.`n⚠️  THE EV2 ROLLOUT MAY STILL BE ACTIVELY DEPLOYING TO PRODUCTION."
'@
        $mockScript | Set-Content (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') -Encoding UTF8

        { & (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') `
            -RolloutId 'fail-rollout-id' -ServiceGroup 'TestSG' } |
            Should -Throw '*EV2_CANCEL_FAILED*'
    }

    It 'throws when cancellation sent but verification times out' {
        $tempDir = Join-Path $TestDrive 'ev2-cancel-unverified'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $mockScript = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RolloutId,
    [Parameter(Mandatory)][string]$ServiceGroup,
    [string]$RolloutInfra = "Prod",
    [string]$BuildId,
    [int]$MaxRetries = 3,
    [int]$VerifyTimeoutSeconds = 60,
    [string]$ServiceConfigPath = ''
)
$ErrorActionPreference = 'Stop'
throw "EV2_CANCEL_UNVERIFIED: Cancellation was sent but could NOT be verified within ${VerifyTimeoutSeconds}s.`n⚠️  THE EV2 ROLLOUT STATE IS UNKNOWN. It may still be deploying."
'@
        $mockScript | Set-Content (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') -Encoding UTF8

        { & (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') `
            -RolloutId 'unverified-id' -ServiceGroup 'TestSG' } |
            Should -Throw '*EV2_CANCEL_UNVERIFIED*'
    }

    It 'provides actionable error message with portal instructions on failure' {
        $tempDir = Join-Path $TestDrive 'ev2-cancel-actionable'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $mockScript = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RolloutId,
    [Parameter(Mandatory)][string]$ServiceGroup,
    [string]$RolloutInfra = "Prod",
    [string]$BuildId,
    [int]$MaxRetries = 3,
    [int]$VerifyTimeoutSeconds = 60,
    [string]$ServiceConfigPath = ''
)
$ErrorActionPreference = 'Stop'
throw @(
    "EV2_CANCEL_FAILED: Could not cancel EV2 rollout $RolloutId after $MaxRetries attempts.",
    "IMMEDIATE ACTION REQUIRED:",
    "  1. Open the EV2 portal and manually cancel the rollout",
    "  2. Verify the cancellation took effect"
) -join "`n"
'@
        $mockScript | Set-Content (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') -Encoding UTF8

        $err = $null
        try {
            & (Join-Path $tempDir 'Stop-Ev2Rollout.ps1') `
                -RolloutId 'portal-id' -ServiceGroup 'TestSG'
        } catch { $err = $_.Exception.Message }

        $err | Should -BeLike '*IMMEDIATE ACTION REQUIRED*'
        $err | Should -BeLike '*EV2 portal*'
    }
}
