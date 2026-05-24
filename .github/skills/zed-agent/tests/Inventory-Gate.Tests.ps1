BeforeAll {
    $script:approveScript = Join-Path $PSScriptRoot '..\scripts\Approve-Inventory.ps1'
    $script:gateScript    = Join-Path $PSScriptRoot '..\scripts\Test-InventoryGate.ps1'
    $script:sdsScript     = Join-Path $PSScriptRoot '..\scripts\Get-StampInventoryFromSds.ps1'

    # Synthetic SDS (used to produce a real hash via Get-StampInventoryFromSds).
    $script:sdsPath = Join-Path $TestDrive 'sds.json'
    $sds = [ordered]@{
        '$schema' = 'https://aka.ms/phobosweb/schema/2022/sds'
        Metadata  = @{ ServiceShortName = 'tst' }
        CloudSettings = @(
            @{ CloudName='Fairfax'; StampSettings=@(
                @{ StampId='usgv-01'; Macros=@{
                    __StampName__='usgv-ff01-tst1'; __ClusterName__='usgv-ff01-tst-01'
                    __DatacenterShortName__='usgv'; __ClusterLocation__='USGov Virginia'
                    __DeploymentName__='usgv-ff01'; __DsmsRegion__='usgovvirginia' } }
            )}
        )
    }
    $sds | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:sdsPath -Encoding UTF8

    # Service-config under TestDrive with sds.<key> + production.approvalRequired.
    $script:svcCfgPath = Join-Path $TestDrive 'service-config.json'
    $cfg = [ordered]@{
        '$schema'      = './service-config.schema.json'
        version        = '1.0'
        service        = @{ name='Test'; displayName='Test'; stampTag='tst' }
        sds = @{
            ServiceUpgrade = @{
                repo     = 'fake'
                branch   = 'main'
                path     = $script:sdsPath
                fileName = 'sds.json'
            }
        }
        inventory = @{
            driftToleranceCount = 0
            production = @{ approvalRequired = $true }
        }
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:svcCfgPath -Encoding UTF8

    $script:readinessPath = Join-Path $TestDrive 'readiness.json'

    # Helper to build a fake Get-StampInventory result that Approve-Inventory will accept.
    function script:Build-InventoryResult {
        param([int]$DriftCount = 0, [int]$Tolerance = 0)
        $sds = & $script:sdsScript -SdsPath $script:sdsPath -Cloud 'Fairfax' -ServiceConfigPath $script:svcCfgPath
        [pscustomobject]@{
            scope       = 'production'
            cloud       = 'Fairfax'
            pipelineKey = 'ServiceUpgrade'
            stamps      = $sds.stamps
            drift       = @()
            kusto       = $null
            sdsReconciliation = [pscustomobject]@{
                hash             = $sds.hash
                source           = $script:sdsPath
                stampCount       = @($sds.stamps).Count
                cloud            = 'Fairfax'
                sdsOnly          = @()
                kustoOnly        = @()
                driftCount       = $DriftCount
                toleranceCount   = $Tolerance
                withinTolerance  = ($DriftCount -le $Tolerance)
            }
        }
    }
}

Describe 'Approve-Inventory + Test-InventoryGate' {

    BeforeEach {
        if (Test-Path $script:readinessPath) { Remove-Item $script:readinessPath -Force }
    }

    Context 'Happy path' {
        It 'persists readiness.inventory with approved=true and pass status' {
            $inv = script:Build-InventoryResult
            $rec = & $script:approveScript -InventoryObject $inv -ApprovedBy 'tester@microsoft.com' -ReadinessPath $script:readinessPath
            $rec.status     | Should -Be 'pass'
            $rec.approved   | Should -BeTrue
            $rec.approvedBy | Should -Be 'tester@microsoft.com'
            Test-Path $script:readinessPath | Should -BeTrue
            $r = Get-Content $script:readinessPath -Raw | ConvertFrom-Json
            $r.inventory.sds.hash | Should -Not -BeNullOrEmpty
        }

        It 'gate returns pass when hash matches and approved' {
            $inv = script:Build-InventoryResult
            & $script:approveScript -InventoryObject $inv -ApprovedBy 'tester@microsoft.com' -ReadinessPath $script:readinessPath | Out-Null
            $v = & $script:gateScript -ServiceConfigPath $script:svcCfgPath -ReadinessPath $script:readinessPath
            $v.verdict | Should -Be 'pass'
        }
    }

    Context 'Drift handling' {
        It 'throws without -Override when status would be drift' {
            $inv = script:Build-InventoryResult -DriftCount 5 -Tolerance 0
            { & $script:approveScript -InventoryObject $inv -ApprovedBy 't@x' -ReadinessPath $script:readinessPath } |
                Should -Throw '*unresolved drift*'
        }

        It 'accepts drift when -Override is set and gate reports pass via overridden' {
            $inv = script:Build-InventoryResult -DriftCount 5 -Tolerance 0
            $rec = & $script:approveScript -InventoryObject $inv -ApprovedBy 't@x' -Override -ReadinessPath $script:readinessPath
            $rec.status     | Should -Be 'drift'
            $rec.overridden | Should -BeTrue
            $v = & $script:gateScript -ServiceConfigPath $script:svcCfgPath -ReadinessPath $script:readinessPath
            $v.verdict | Should -Be 'pass'
        }
    }

    Context 'Gate verdicts' {
        It 'returns missing when readiness has no inventory section' {
            '{}' | Set-Content -LiteralPath $script:readinessPath -Encoding UTF8
            $v = & $script:gateScript -ServiceConfigPath $script:svcCfgPath -ReadinessPath $script:readinessPath
            $v.verdict | Should -Be 'missing'
        }

        It 'returns notApproved when approved=false' {
            $bad = @{ inventory = @{ ranAt='2026-05-24T00:00:00Z'; status='pass'; pipelineKey='ServiceUpgrade'; approved=$false; sds=@{ hash='abc' } } }
            $bad | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:readinessPath -Encoding UTF8
            $v = & $script:gateScript -ServiceConfigPath $script:svcCfgPath -ReadinessPath $script:readinessPath
            $v.verdict | Should -Be 'notApproved'
        }

        It 'returns hashDrift when the SDS hash recorded does not match the live SDS hash' {
            $inv = script:Build-InventoryResult
            & $script:approveScript -InventoryObject $inv -ApprovedBy 't@x' -ReadinessPath $script:readinessPath | Out-Null
            # Mutate the SDS so hash will change.
            $obj = Get-Content $script:sdsPath -Raw | ConvertFrom-Json
            $obj.CloudSettings[0].StampSettings += [pscustomobject]@{
                StampId='usgv-99'
                Macros=[pscustomobject]@{
                    __StampName__='usgv-ff01-tst99'; __ClusterName__='usgv-ff01-tst-99'
                    __DatacenterShortName__='usgv'; __ClusterLocation__='USGov Virginia'
                    __DeploymentName__='usgv-ff01'; __DsmsRegion__='usgovvirginia' }
            }
            $obj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:sdsPath -Encoding UTF8
            $v = & $script:gateScript -ServiceConfigPath $script:svcCfgPath -ReadinessPath $script:readinessPath
            $v.verdict | Should -Be 'hashDrift'
        }

        It 'returns skip when service-config has approvalRequired=false' {
            $cfg = Get-Content $script:svcCfgPath -Raw | ConvertFrom-Json
            $cfg.inventory.production.approvalRequired = $false
            $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:svcCfgPath -Encoding UTF8
            $v = & $script:gateScript -ServiceConfigPath $script:svcCfgPath -ReadinessPath $script:readinessPath
            $v.verdict | Should -Be 'skip'
        }
    }
}
