BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\scripts\Get-StampInventoryFromSds.ps1'

    # Synthetic mini-SDS shaped exactly like Phobos 2022 (DataMover/Prot).
    $script:fixtureRoot = Join-Path $TestDrive 'sds'
    New-Item -ItemType Directory -Path $script:fixtureRoot -Force | Out-Null
    $script:sdsPath = Join-Path $script:fixtureRoot 'ServiceDatacenterSettingsConfig.json'

    $sds = [ordered]@{
        '$schema' = 'https://aka.ms/phobosweb/schema/2022/sds'
        Version   = '2022'
        Metadata  = @{
            PlatformShortName = 'tst'
            ServiceShortName  = 'tst'
            ServiceName       = 'TestSFApplication'
        }
        DefaultResources = @()
        CloudSettings    = @(
            @{
                CloudName     = 'Canary'
                Macros        = @{ __Cloud__ = 'can02' }
                Resources     = @()
                StampSettings = @(
                    @{ StampId = 'ea-01'; Macros = @{
                          __DsmsRegion__='asiaeast'; __StampSuffix__='aaaaa'
                          __DatacenterShortName__='ea'; __ClusterName__='ea-can02-tst-01'
                          __ClusterLocation__='East Asia'; __StampName__='ea-can02-tst1'
                          __DeploymentName__='ea-can02'; __DeploymentShortName__='eacan02' };
                       Resources = @() }
                    @{ StampId = 'ea-02'; Macros = @{
                          __DsmsRegion__='asiaeast'; __StampSuffix__='bbbbb'
                          __DatacenterShortName__='ea'; __ClusterName__='ea-can02-tst-02'
                          __ClusterLocation__='East Asia'; __StampName__='ea-can02-tst2'
                          __DeploymentName__='ea-can02'; __DeploymentShortName__='eacan02' };
                       Resources = @() }
                )
            },
            @{
                CloudName     = 'Public'
                Macros        = @{ __Cloud__ = 'pod01' }
                Resources     = @()
                StampSettings = @(
                    @{ StampId = 'eus-01'; Macros = @{
                          __DsmsRegion__='eastus'; __StampSuffix__='ccccc'
                          __DatacenterShortName__='eus'; __ClusterName__='eus-pod01-tst-01'
                          __ClusterLocation__='East US'; __StampName__='eus-pod01-tst1'
                          __DeploymentName__='eus-pod01'; __DeploymentShortName__='euspod01' };
                       Resources = @() }
                    @{ StampId = 'we-01'; Macros = @{
                          __DsmsRegion__='westeurope'; __StampSuffix__='ddddd'
                          __DatacenterShortName__='we'; __ClusterName__='we-pod01-tst-01'
                          __ClusterLocation__='West Europe'; __StampName__='we-pod01-tst1'
                          __DeploymentName__='we-pod01'; __DeploymentShortName__='wepod01' };
                       Resources = @() }
                    @{ StampId = 'we-02'; Macros = @{
                          __DsmsRegion__='westeurope'; __StampSuffix__='eeeee'
                          __DatacenterShortName__='we'; __ClusterName__='we-pod01-tst-02'
                          __ClusterLocation__='West Europe'; __StampName__='we-pod01-tst2'
                          __DeploymentName__='we-pod01'; __DeploymentShortName__='wepod01' };
                       Resources = @() }
                )
            }
        )
    }
    $sds | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:sdsPath -Encoding UTF8

    # Empty service-config so the script picks up defaults (no sdsFieldMapping override).
    $script:svcCfgPath = Join-Path $script:fixtureRoot 'service-config.json'
    '{}' | Set-Content -LiteralPath $script:svcCfgPath -Encoding UTF8
}

Describe 'Get-StampInventoryFromSds' {

    Context 'Default extraction (no field-mapping override)' {
        It 'returns 5 stamps across 2 clouds for the synthetic fixture' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath
            $r.stamps.Count    | Should -Be 5
            $r.byCloud.Keys    | Should -Contain 'Canary'
            $r.byCloud.Keys    | Should -Contain 'Public'
            $r.byCloud['Canary'].Count | Should -Be 2
            $r.byCloud['Public'].Count | Should -Be 3
        }

        It 'populates service short name from Metadata' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath
            $r.service | Should -Be 'tst'
        }

        It 'extracts every macro field for the first stamp' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath
            $s = $r.stamps | Where-Object { $_.stampId -eq 'eus-01' } | Select-Object -First 1
            $s.cloud          | Should -Be 'Public'
            $s.stampName      | Should -Be 'eus-pod01-tst1'
            $s.clusterName    | Should -Be 'eus-pod01-tst-01'
            $s.dcShortName    | Should -Be 'eus'
            $s.region         | Should -Be 'East US'
            $s.deploymentName | Should -Be 'eus-pod01'
            $s.dsmsRegion     | Should -Be 'eastus'
        }

        It 'reports zero errors for a well-formed SDS' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath
            $r.errors.Count | Should -Be 0
        }

        It 'emits a non-empty stable hash' {
            $r1 = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath
            $r2 = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath
            $r1.hash | Should -Not -BeNullOrEmpty
            $r1.hash | Should -Be $r2.hash
            $r1.hash.Length | Should -Be 64
        }
    }

    Context 'Cloud filter' {
        It 'returns only the requested cloud when -Cloud is supplied' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath -Cloud Public
            $r.stamps.Count    | Should -Be 3
            $r.byCloud.Keys    | Should -Be @('Public')
        }

        It 'matches CloudName case-insensitively' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath -Cloud 'public'
            $r.stamps.Count | Should -Be 3
        }

        It 'returns zero stamps for an unknown cloud' {
            $r = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath -Cloud 'Fairfax'
            $r.stamps.Count | Should -Be 0
        }
    }

    Context 'Detect mode' {
        It 'returns mapping plus sample values from the first stamp' {
            $d = & $script:scriptPath -SdsPath $script:sdsPath -ServiceConfigPath $script:svcCfgPath -Detect
            $d.service                                      | Should -Be 'tst'
            $d.schemaUri                                    | Should -Be 'https://aka.ms/phobosweb/schema/2022/sds'
            $d.mapping.cloudArrayPath                       | Should -Be 'CloudSettings'
            $d.mapping.stampNamePath                        | Should -Be 'Macros.__StampName__'
            $d.samples.stampNamePath.sample                 | Should -Be 'ea-can02-tst1'
            $d.samples.dcShortNamePath.sample               | Should -Be 'ea'
            $d.samples.cloudNameField.sample                | Should -Be 'Canary'
            $d.samples.cloudArrayPath.sample                | Should -Match '<array len 2>'
        }
    }

    Context 'FieldMapping override' {
        It 'honors -FieldMapping when the SDS uses non-default paths' {
            $weird = Join-Path $TestDrive 'weird.json'
            $obj = [ordered]@{
                schemaUri = 'custom'
                Metadata  = @{ ServiceShortName = 'wd' }
                Sites = @(
                    @{ Name = 'PUB'; Stamps = @(
                        @{ Id='x-1'; Region='East US'; Dc='eus'; Name='eus-pub-wd1'; Cluster='eus-pub-wd-01'; Dep='eus-pub'; Dsms='eastus' }
                        @{ Id='x-2'; Region='West US'; Dc='wus'; Name='wus-pub-wd1'; Cluster='wus-pub-wd-01'; Dep='wus-pub'; Dsms='westus' }
                    )}
                )
            }
            $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $weird -Encoding UTF8

            $mapping = @{
                cloudArrayPath     = 'Sites'
                cloudNameField     = 'Name'
                stampsArrayField   = 'Stamps'
                stampIdField       = 'Id'
                stampNamePath      = 'Name'
                clusterNamePath    = 'Cluster'
                dcShortNamePath    = 'Dc'
                regionPath         = 'Region'
                deploymentNamePath = 'Dep'
                dsmsRegionPath     = 'Dsms'
            }
            $r = & $script:scriptPath -SdsPath $weird -ServiceConfigPath $script:svcCfgPath -FieldMapping $mapping
            $r.stamps.Count          | Should -Be 2
            $r.byCloud.Keys          | Should -Contain 'PUB'
            ($r.stamps | Where-Object stampId -eq 'x-1').dcShortName | Should -Be 'eus'
        }
    }

    Context 'Error handling' {
        It 'throws when the SDS file is missing' {
            { & $script:scriptPath -SdsPath (Join-Path $TestDrive 'nope.json') -ServiceConfigPath $script:svcCfgPath } |
                Should -Throw '*not found*'
        }

        It 'throws when the cloud-array path does not resolve' {
            $bad = Join-Path $TestDrive 'bad.json'
            '{ "Metadata": {}, "NotCloudSettings": [] }' | Set-Content -LiteralPath $bad -Encoding UTF8
            { & $script:scriptPath -SdsPath $bad -ServiceConfigPath $script:svcCfgPath } |
                Should -Throw "*'CloudSettings'*"
        }

        It 'records a per-stamp error when StampId is missing but continues processing' {
            $bad = Join-Path $TestDrive 'partial.json'
            $obj = [ordered]@{
                Metadata = @{ ServiceShortName = 'tst' }
                CloudSettings = @(
                    @{ CloudName='Public'; StampSettings = @(
                        @{ Macros = @{ __StampName__='no-id-stamp' } }
                    )}
                )
            }
            $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $bad -Encoding UTF8
            $r = & $script:scriptPath -SdsPath $bad -ServiceConfigPath $script:svcCfgPath
            $r.errors.Count | Should -BeGreaterThan 0
            $r.errors[0]    | Should -Match 'no '''  # quoted 'StampId'
            $r.stamps.Count | Should -Be 1
        }
    }
}
