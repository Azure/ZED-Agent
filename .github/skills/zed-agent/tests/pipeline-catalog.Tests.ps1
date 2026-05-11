$skillDir = Split-Path $PSScriptRoot -Parent
$catalogPath = Join-Path $skillDir 'pipeline-catalog.json'
$catalogJson = Get-Content $catalogPath -Raw -Encoding UTF8
try {
    $catalogPreview = $catalogJson | ConvertFrom-Json
    $isSkeleton = (-not $catalogPreview.officialBuild.id) -or ($catalogPreview.officialBuild.id -eq 0) -or
                  (($catalogPreview.canary.PSObject.Properties | Measure-Object).Count -eq 0)
} catch {
    $isSkeleton = $true
}

Describe 'Pipeline Catalog Validation' {
    BeforeAll {
        $skillDir = Split-Path $PSScriptRoot -Parent
        $catalogPath = Join-Path $skillDir 'pipeline-catalog.json'
        $catalogJson = Get-Content $catalogPath -Raw -Encoding UTF8
    }

    Context 'Valid catalog' {
        It 'pipeline-catalog.json is valid JSON' {
            { $catalogJson | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'has officialBuild with id and name' -Skip:$isSkeleton {
            $catalog = $catalogJson | ConvertFrom-Json
            $catalog.officialBuild | Should -Not -BeNullOrEmpty
            $catalog.officialBuild.id | Should -BeGreaterThan 0
            $catalog.officialBuild.name | Should -Not -BeNullOrEmpty
        }

        It 'has at least one canary pipeline' -Skip:$isSkeleton {
            $catalog = $catalogJson | ConvertFrom-Json
            $canaryCount = ($catalog.canary.PSObject.Properties | Measure-Object).Count
            $canaryCount | Should -BeGreaterOrEqual 1
        }

        It 'has at least one production pipeline' -Skip:$isSkeleton {
            $catalog = $catalogJson | ConvertFrom-Json
            $prodCount = ($catalog.production.PSObject.Properties | Measure-Object).Count
            $prodCount | Should -BeGreaterOrEqual 1
        }

        It 'all canary pipelines have name and id' {
            $catalog = $catalogJson | ConvertFrom-Json
            foreach ($prop in $catalog.canary.PSObject.Properties) {
                $p = $prop.Value
                $p.name | Should -Not -BeNullOrEmpty
                $p.id | Should -BeGreaterThan 0
            }
        }

        It 'all canary pipelines have templateParameters' {
            $catalog = $catalogJson | ConvertFrom-Json
            foreach ($prop in $catalog.canary.PSObject.Properties) {
                $p = $prop.Value
                $p.templateParameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'canaryRouting.mode is static or cluster-type when present' {
            $catalog = $catalogJson | ConvertFrom-Json
            if ($catalog.PSObject.Properties.Name -contains 'canaryRouting' -and $catalog.canaryRouting.mode) {
                $catalog.canaryRouting.mode | Should -BeIn @('static', 'cluster-type')
                if ($catalog.canaryRouting.mode -eq 'cluster-type') {
                    $catalog.canaryRouting.clusterTypeMap | Should -Not -BeNullOrEmpty
                    foreach ($mapping in $catalog.canaryRouting.clusterTypeMap.PSObject.Properties) {
                        $catalog.canary.PSObject.Properties.Name | Should -Contain $mapping.Value
                    }
                }
            }
        }

        It 'productionRouting.mode is static or cluster-type when present' {
            $catalog = $catalogJson | ConvertFrom-Json
            if ($catalog.PSObject.Properties.Name -contains 'productionRouting' -and $catalog.productionRouting.mode) {
                $catalog.productionRouting.mode | Should -BeIn @('static', 'cluster-type')
                if ($catalog.productionRouting.mode -eq 'cluster-type') {
                    $catalog.productionRouting.clusterTypeMap | Should -Not -BeNullOrEmpty
                    foreach ($mapping in $catalog.productionRouting.clusterTypeMap.PSObject.Properties) {
                        $catalog.production.PSObject.Properties.Name | Should -Contain $mapping.Value
                    }
                }
            }
        }

        It 'officialBuild sourceBranch uses runtime placeholder' {
            $catalog = $catalogJson | ConvertFrom-Json
            $catalog.officialBuild.sourceBranch | Should -BeLike '*{{currentBranch}}*'
        }
    }
}
