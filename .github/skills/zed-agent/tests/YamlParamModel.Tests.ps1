BeforeAll {
    $script:libPath          = Join-Path $PSScriptRoot '..\scripts\lib\YamlParamModel.ps1'
    $script:introspectPath   = Join-Path $PSScriptRoot '..\scripts\Get-PipelineYamlIntrospection.ps1'
    . $script:libPath

    # Two spellings of the SAME parameter block. ADO's /preview endpoint emits the
    # column-0 sequence form; hand-written pipeline YAML usually indents. Both are
    # valid YAML and must extract identically.
    $script:indentedYaml = @'
name: Fixture.Indented

parameters:
  - name: alphaRegions
    type: string
    default: 'regions(one,two)'
  - name: alphaStamps
    type: string
    default: '*'

stages:
  - stage: Rollout
'@

    $script:columnZeroYaml = @'
name: Fixture.ColumnZero

parameters:
- name: "alphaRegions"
  type: string
  default: 'regions(one,two)'
- name: "alphaStamps"
  type: string
  default: '*'

stages:
- stage: Rollout
'@
}

Describe 'Get-YamlParameterBlock' {

    It 'extracts identically from indented and column-0 sequence forms' {
        $a = @(Get-YamlParameterBlock -Yaml $script:indentedYaml)
        $b = @(Get-YamlParameterBlock -Yaml $script:columnZeroYaml)

        $a.Count | Should -Be 2
        $b.Count | Should -Be 2
        ($a | ForEach-Object { $_.name }) | Should -Be @('alphaRegions', 'alphaStamps')
        ($b | ForEach-Object { $_.name }) | Should -Be @('alphaRegions', 'alphaStamps')
        $b[0].default | Should -Be $a[0].default
        $b[1].default | Should -Be $a[1].default
    }

    It 'stops at the next column-0 mapping key and does not bleed into later sections' {
        $params = @(Get-YamlParameterBlock -Yaml $script:columnZeroYaml)
        ($params | ForEach-Object { $_.name }) | Should -Not -Contain 'stage'
        ($params | ForEach-Object { $_.name }) | Should -Not -Contain 'Rollout'
    }

    It 'returns an empty array when there is no parameters block' {
        @(Get-YamlParameterBlock -Yaml "name: NoParams`n`nstages:`n- stage: X") |
            Should -HaveCount 0
    }
}

Describe 'Get-ParameterPartitionModel' {

    It 'discovers partitions for a synthetic service whose names do not exist in the test target' {
        # Deliberately invented partition names. Nothing here appears in any real
        # catalog — proves discovery is driven by the quad shape, not a known list.
        $names = @(
            'ZorpRegions', 'ZorpExcludeRegions', 'Zorpstamps', 'ZorpExcludestamps', 'ZorpScript',
            'QuuxRegions', 'QuuxExcludeRegions', 'Quuxstamps', 'QuuxExcludestamps', 'QuuxScript',
            'rolloutType'
        )
        $m = Get-ParameterPartitionModel -ParameterNames $names

        ($m.partitions | ForEach-Object { $_.name } | Sort-Object) | Should -Be @('Quux', 'Zorp')
        $m.unmatched | Should -Contain 'rolloutType'

        $zorp = $m.partitions | Where-Object { $_.name -eq 'Zorp' }
        $zorp.facets.regions        | Should -Be 'ZorpRegions'
        $zorp.facets.excludeRegions | Should -Be 'ZorpExcludeRegions'
        $zorp.facets.stamps         | Should -Be 'Zorpstamps'
        $zorp.facets.excludeStamps  | Should -Be 'ZorpExcludestamps'
        $zorp.facets.script         | Should -Be 'ZorpScript'
    }

    It 'folds a shorter prefix into the longer partition that owns the head facet' {
        $names = @('LongoRegions', 'Longostamps', 'LongoScript', 'LonExcludeRegions')
        $m = Get-ParameterPartitionModel -ParameterNames $names

        ($m.partitions | ForEach-Object { $_.name }) | Should -Be @('Longo')
        ($m.partitions[0].aliases) | Should -Contain 'Lon'
        $m.partitions[0].facets.excludeRegions | Should -Be 'LonExcludeRegions'
    }

    It 'qualifies a partition on two facets even without the head facet' {
        $m = Get-ParameterPartitionModel -ParameterNames @('BetaRegions', 'Betastamps')
        ($m.partitions | ForEach-Object { $_.name }) | Should -Be @('Beta')
    }

    It 'does not invent a partition from a single facet' {
        $m = Get-ParameterPartitionModel -ParameterNames @('GammaRegions', 'rolloutType')
        $m.partitions | Should -HaveCount 0
        $m.unmatched  | Should -Contain 'GammaRegions'
    }

    It 'exposes a flat lookup for parameters carrying no partition prefix' {
        $m = Get-ParameterPartitionModel -ParameterNames @('Regions', 'stamps', 'ExcludeRegions')
        $m.partitions      | Should -HaveCount 0
        $m.flat.regions        | Should -Be 'Regions'
        $m.flat.stamps         | Should -Be 'stamps'
        $m.flat.excludeRegions | Should -Be 'ExcludeRegions'
    }
}

Describe 'Get-ParameterValueShape' {

    It 'classifies <expected> for <label>' -ForEach @(
        @{ label = 'bare asterisk';     value = '*';                        expected = 'wildcard';        container = $null      }
        @{ label = 'quoted asterisk';   value = '"*"';                      expected = 'wildcard';        container = $null      }
        @{ label = 'array literal';     value = '@("a","b")';               expected = 'list';            container = '@()'      }
        @{ label = 'regions wildcard';  value = 'regions(*)';               expected = 'regionsWildcard'; container = 'regions'  }
        @{ label = 'regions list';      value = 'regions(eastus,westus)';   expected = 'regionsList';     container = 'regions'  }
        @{ label = 'empty array';       value = '@()';                      expected = 'empty';           container = '@()'      }
        @{ label = 'blank string';      value = '';                         expected = 'empty';           container = $null      }
        @{ label = 'map literal';       value = '@{ a = 1 }';               expected = 'map';             container = '@{}'      }
        @{ label = 'bare csv';          value = 'eus-01,we-01';             expected = 'scalar';          container = $null      }
        @{ label = 'plain scalar';      value = 'Hotfix';                   expected = 'scalar';          container = $null      }
    ) {
        $s = Get-ParameterValueShape -Value $value
        $s.shape     | Should -Be $expected
        $s.container | Should -Be $container
    }

    It 'flags emptiness independently of shape' {
        (Get-ParameterValueShape -Value '@()').isEmpty | Should -BeTrue
        (Get-ParameterValueShape -Value '*').isEmpty   | Should -BeFalse
    }

    It 'reports the observed function token as the container rather than assuming a name' {
        # No allow-list of container names: whatever token the service used is echoed back.
        (Get-ParameterValueShape -Value 'zones(a,b)').container | Should -Be 'zones'
        (Get-ParameterValueShape -Value 'zones(a,b)').shape     | Should -Be 'regionsList'
    }
}

Describe 'Build-ParameterModel' {

    BeforeAll {
        $script:runA = [pscustomobject]@{
            runId = 1; releaseGroup = 'rel-1'
            templateParameters = [pscustomobject]@{ steady = '*'; drifting = 'regions(a)'; }
        }
        $script:runB = [pscustomobject]@{
            runId = 2; releaseGroup = 'rel-2'
            templateParameters = [pscustomobject]@{ steady = '*'; drifting = 'regions(b)'; }
        }
        # Same release as runB — must NOT count as independent evidence.
        $script:runBTwin = [pscustomobject]@{
            runId = 3; releaseGroup = 'rel-2'
            templateParameters = [pscustomobject]@{ steady = '*'; drifting = 'regions(b)'; }
        }
    }

    It 'marks everything low-confidence when only one release is observed' {
        $m = Build-ParameterModel -Runs @($script:runA)
        $m.independentReleaseCount | Should -Be 1
        $m.model.steady.stability     | Should -Be 'constant'
        $m.model.steady.lowConfidence | Should -BeTrue
    }

    It 'clears low-confidence for a constant value across two independent releases' {
        $m = Build-ParameterModel -Runs @($script:runA, $script:runB)
        $m.independentReleaseCount    | Should -Be 2
        $m.model.steady.stability     | Should -Be 'constant'
        $m.model.steady.lowConfidence | Should -BeFalse
        $m.model.steady.observedIn    | Should -Be 2
    }

    It 'reports a value that changes between releases as volatile' {
        $m = Build-ParameterModel -Runs @($script:runA, $script:runB)
        $m.model.drifting.stability | Should -Be 'volatile'
        @($m.model.drifting.observedValues) | Should -HaveCount 2
    }

    It 'counts independence per release group, not per run' {
        $m = Build-ParameterModel -Runs @($script:runB, $script:runBTwin)
        $m.independentReleaseCount    | Should -Be 1
        $m.model.steady.lowConfidence | Should -BeTrue
    }

    It 'records a declared-but-never-observed parameter as unobserved' {
        $declared = @([pscustomobject]@{ name = 'ghost'; default = 'x' })
        $m = Build-ParameterModel -Runs @($script:runA) -DeclaredParameters $declared
        $m.model.ghost.stability      | Should -Be 'unobserved'
        $m.model.ghost.declaredDefault | Should -Be 'x'
        $m.model.ghost.lowConfidence  | Should -BeTrue
    }

    It 'carries the value shape onto the model entry' {
        $m = Build-ParameterModel -Runs @($script:runA)
        $m.model.steady.shape      | Should -Be 'wildcard'
        $m.model.drifting.container | Should -Be 'regions'
    }
}

Describe 'Get-PipelineYamlIntrospection empty-extraction guard' {

    It 'throws rather than returning a null parameter set' {
        { & $script:introspectPath -Content "name: Empty`n`nstages:`n- stage: X" -SourceLabel 'unit-test' } |
            Should -Throw '*no parameters*'
    }

    It 'returns an empty parameter set when the caller opts in explicitly' {
        $r = & $script:introspectPath -Content "name: Empty`n`nstages:`n- stage: X" `
                -SourceLabel 'unit-test' -AllowEmptyParameters
        @($r.parameters) | Should -HaveCount 0
    }

    It 'extracts the same parameters from column-0 and indented forms end to end' {
        $a = & $script:introspectPath -Content $script:indentedYaml   -SourceLabel 'unit-test'
        $b = & $script:introspectPath -Content $script:columnZeroYaml -SourceLabel 'unit-test'
        @($a.parameters).Count | Should -Be @($b.parameters).Count
        ($b.parameters | ForEach-Object { $_.name }) |
            Should -Be ($a.parameters | ForEach-Object { $_.name })
    }
}
