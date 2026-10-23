Describe 'Assert-GeographyCoverage — regions(*) wildcard (BCM2610_2 regression)' {
    # Regression 2026-10-20: BCM-PROD resolves PubRegions/MCRegions/FFRegions = regions(*) (full
    # rollout) and the L-16 gate reported "33 of 33 geographies not covered" because '*' was
    # looked up as a region name. A wildcard = every region of the parameter's cloud; only the
    # expected (Public) cloud's partition may count, and only when its Script switch is on.
    BeforeAll {
        # Self-contained: a stub Get-RegionMapping (12 Public geographies incl. Japan) next to a copy
        # of the gate, so the test needs neither a service's ASC region source nor the network.
        $src = Join-Path $PSScriptRoot '..\scripts\Assert-GeographyCoverage.ps1'
        $gateDir = Join-Path $TestDrive 'geo-wildcard'
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        @'
param($ServiceConfigPath, $ExcludeRegions = @(), [switch]$AllClouds, $CloudName)
$rows = @(
    @('East Asia','eastasia','ea','Asia Pacific'), @('Southeast Asia','southeastasia','sea','Asia Pacific')
    @('Japan East','japaneast','jpe','Japan'), @('Japan West','japanwest','jpw','Japan')
    @('North Europe','northeurope','ne','Europe'), @('West Europe','westeurope','we','Europe')
    @('East US','eastus','eus','United States'), @('West US','westus','wus','United States')
    @('UAE Central','uaecentral','uac','Middle East'), @('South Africa North','southafricanorth','san','Africa')
    @('Brazil South','brazilsouth','brs','Brazil'), @('Canada Central','canadacentral','cnc','Canada')
    @('Australia East','australiaeast','ae','Australia'), @('Korea Central','koreacentral','krc','Korea')
    @('UK South','uksouth','uks','United Kingdom'), @('India Central','centralindia','inc','India')
)
$rows | Where-Object { $ExcludeRegions -notcontains $_[1] } | ForEach-Object {
    [PSCustomObject]@{ DataCenterName = $_[0]; RegionShortName = $_[1]; StampPrefix = $_[2]; Ev2Geography = $_[3]; StampCount = 1; DatacenterType = @('ACTIVE') }
}
'@ | Set-Content (Join-Path $gateDir 'Get-RegionMapping.ps1') -Encoding UTF8
        Get-Content $src -Raw | Set-Content (Join-Path $gateDir 'Assert-GeographyCoverage.ps1') -Encoding UTF8
        Copy-Item (Join-Path (Split-Path $src -Parent) 'lib') (Join-Path $gateDir 'lib') -Recurse -Force
        $gate = Join-Path $gateDir 'Assert-GeographyCoverage.ps1'
        function script:New-ProdParams([hashtable]$Overrides = @{}) {
            $p = @{
                PublicScript = 'True'; Publicstamps = '*'; PublicExcludestamps = '@()'; PubRegions = 'regions(*)'; PubExcludeRegions = ' '
                MCScript = 'True'; MCstamps = '*'; MCExcludestamps = '@()'; MCRegions = 'regions(*)'
                FFScript = 'True'; FFstamps = '*'; FFExcludestamps = '@()'; FFRegions = 'regions(*)'
                BleuScript = 'False'; BleuRegions = 'regions(*)'
            }
            foreach ($k in $Overrides.Keys) { $p[$k] = $Overrides[$k] }
            return $p
        }
        function script:Invoke-Gate([hashtable]$Params) {
            & $gate -PipelineParams @{ 'BCM-PROD' = $Params } -ReleaseId 'TEST' -SkipPersist 6>$null 3>$null
        }
    }

    It 'PubRegions = regions(*) with PublicScript=True covers every expected geography' {
        $g = Invoke-Gate (New-ProdParams)
        $g.missingCount | Should -Be 0
        $g.coveredCount | Should -Be $g.expectedCount
        $g.expectedCount | Should -BeGreaterThan 10
    }

    It 'a wildcard in another cloud partition (MC/FF/Bleu) does not cover Public geographies' {
        { Invoke-Gate (New-ProdParams @{ PubRegions = 'regions()' }) } | Should -Throw '*GEOGRAPHY_COVERAGE_GAP*'
    }

    It 'a wildcard whose cloud switch is off covers nothing' {
        { Invoke-Gate (New-ProdParams @{ PublicScript = 'False' }) } | Should -Throw '*GEOGRAPHY_COVERAGE_GAP*'
    }

    It 'the partition ExcludeRegions entries are subtracted from the wildcard' {
        { Invoke-Gate (New-ProdParams @{ PubExcludeRegions = 'regions(japaneast,japanwest)' }) } | Should -Throw '*Japan*'
    }

    It 'a flat Regions = regions(*) (single-cloud service) covers everything' {
        $g = Invoke-Gate @{ Regions = 'regions(*)' }
        $g.missingCount | Should -Be 0
    }

    It 'explicit region lists keep working' {
        { Invoke-Gate (New-ProdParams @{ PubRegions = 'regions(eastasia)' }) } | Should -Throw '*GEOGRAPHY_COVERAGE_GAP*'
    }
}
