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

        It 'has officialBuild with id and name' {
            $catalog = $catalogJson | ConvertFrom-Json
            $catalog.officialBuild | Should -Not -BeNullOrEmpty
            $catalog.officialBuild.id | Should -BeGreaterThan 0
            $catalog.officialBuild.name | Should -Not -BeNullOrEmpty
        }

        It 'has 4 canary pipelines' {
            $catalog = $catalogJson | ConvertFrom-Json
            $catalog.canary.Count | Should -Be 4
        }

        It 'has 4 production pipelines' {
            $catalog = $catalogJson | ConvertFrom-Json
            $catalog.production.Count | Should -Be 4
        }

        It 'all canary pipelines have name and id' {
            $catalog = $catalogJson | ConvertFrom-Json
            foreach ($p in $catalog.canary) {
                $p.name | Should -Not -BeNullOrEmpty
                $p.id | Should -BeGreaterThan 0
            }
        }

        It 'all canary pipelines have templateParameters' {
            $catalog = $catalogJson | ConvertFrom-Json
            foreach ($p in $catalog.canary) {
                $p.templateParameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'officialBuild sourceBranch uses runtime placeholder' {
            $catalog = $catalogJson | ConvertFrom-Json
            $catalog.officialBuild.sourceBranch | Should -BeLike '*{{currentBranch}}*'
        }
    }
}
