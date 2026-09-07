<#
.SYNOPSIS
    Pester tests for the P3 (model-first token resolution) and P4 (pre-POST payload
    gate) hardening work, plus the YAML-quoting prerequisite.

.DESCRIPTION
    Every fixture in this file uses a SYNTHETIC service whose clouds, partitions and
    parameter names deliberately do NOT match the currently onboarded service. That is
    the genericity proof: if any of these pass only because of a hard-coded MAB name,
    they fail here.
#>

BeforeAll {
    $script:LibPath    = Join-Path $PSScriptRoot '..\scripts\lib\YamlParamModel.ps1'
    $script:ScriptPath = Join-Path $PSScriptRoot '..\scripts\Resolve-TemplateParams.ps1'
    $script:AssertPath = Join-Path $PSScriptRoot '..\scripts\Assert-ParameterPayload.ps1'
    . $script:LibPath

    # Synthetic service vocabulary — intentionally nothing like the onboarded service.
    #   clouds     : Terra / Aqua / Ember      (not Public/Fairfax/Mooncake)
    #   partitions : TerraScript / AquaScript / EmberScript
    #   params     : Terrastamps / TerraRegions / ...
    function New-SyntheticCatalog {
        param(
            [hashtable]$TemplateParameters,
            [array]$DeclaredParameters = @(),
            [hashtable]$LearnedModel,
            [array]$LearnedRuns = @(),
            [string]$Scope = 'production',
            [string]$PipelineKey = 'SYNTH-PROD'
        )
        $entry = @{
            name               = 'Synthetic Prod Pipeline'
            id                 = 909090
            clusterType        = 'SYNTH'
            sourceBranch       = 'refs/heads/{{currentBranch}}'
            templateParameters = $TemplateParameters
        }
        if ($DeclaredParameters.Count -gt 0) {
            $entry['yamlIntrospection'] = @{
                source     = 'test'
                parameters = $DeclaredParameters
                partitions = @(
                    @{ scriptParam = 'TerraScript'; params = @('Terrastamps', 'TerraRegions', 'TerraExcludestamps') }
                    @{ scriptParam = 'AquaScript';  params = @('Aquastamps', 'AquaRegions') }
                    @{ scriptParam = 'EmberScript'; params = @('Emberstamps', 'EmberRegions') }
                )
            }
        }
        if ($LearnedModel) {
            $entry['_learnedFrom'] = @{
                updatedAt = '2026-01-01T00:00:00Z'
                runs      = $LearnedRuns
                model     = $LearnedModel
            }
        }
        $catalog = @{
            officialBuild    = @{ name = 'OB'; id = 1; sourceBranch = 'refs/heads/main'; templateParameters = @{} }
            ev2ServiceGroups = @{}
            ev2CloudCoverage = @{}
            canary           = @{}
            production       = @{}
        }
        $catalog[$Scope] = @{ $PipelineKey = $entry }
        # The synthetic service filters its fleet by cluster type, like any service whose
        # stamps host more than one payload. This is what makes a stamp with no
        # clusterType ambiguous rather than merely untagged.
        $catalog["$($Scope)Routing"] = @{ mode = 'cluster-type' }
        return $catalog
    }

    function New-SyntheticConfig {
        param(
            [hashtable]$Production = @{},
            [hashtable]$CcoaExclusions = @{},
            [hashtable]$Extra = @{}
        )
        $cfg = @{ inventory = @{ canary = @{ stamps = @() } } }
        if ($Production.Count -gt 0)      { $cfg.inventory['production']     = $Production }
        if ($CcoaExclusions.Count -gt 0)  { $cfg.inventory['ccoaExclusions'] = $CcoaExclusions }
        foreach ($k in $Extra.Keys)       { $cfg.inventory[$k]               = $Extra[$k] }
        return $cfg
    }

    function Invoke-SynthResolver {
        param(
            [hashtable]$Catalog,
            [hashtable]$ServiceConfig,
            [string]$Scope = 'production',
            [string]$PipelineKey = 'SYNTH-PROD',
            [string]$CurrentBranch = 'releases/M9',
            [switch]$TestMode
        )
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "p3p4-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $cfgPath = Join-Path $tmpDir 'service-config.json'
        $catPath = Join-Path $tmpDir 'pipeline-catalog.json'
        $Catalog       | ConvertTo-Json -Depth 12 | Set-Content $catPath -Encoding UTF8
        $ServiceConfig | ConvertTo-Json -Depth 12 | Set-Content $cfgPath -Encoding UTF8
        try {
            $params = @{
                PipelineKey         = $PipelineKey
                Scope               = $Scope
                CurrentBranch       = $CurrentBranch
                ServiceConfigPath   = $cfgPath
                PipelineCatalogPath = $catPath
            }
            if ($TestMode) { $params['TestMode'] = $true }
            $out = & $script:ScriptPath @params 3>$null
            return $out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['templateParameters'] }
        }
        finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    function New-Declared {
        param([string]$Name, [string]$Type = 'string', $Default = '', [array]$Values)
        $d = @{ name = $Name; type = $Type; default = $Default }
        if ($PSBoundParameters.ContainsKey('Values')) { $d['values'] = $Values }
        return $d
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Prerequisite — ConvertFrom-YamlScalarQuoting' {

    It "strips a matched single-quote pair" {
        ConvertFrom-YamlScalarQuoting "'develop'" | Should -Be 'develop'
    }
    It "strips a matched double-quote pair" {
        ConvertFrom-YamlScalarQuoting '"develop"' | Should -Be 'develop'
    }
    It "leaves an unmatched leading quote alone" {
        ConvertFrom-YamlScalarQuoting "'develop" | Should -Be "'develop"
    }
    It "leaves mismatched quote characters alone" {
        ConvertFrom-YamlScalarQuoting "'develop`"" | Should -Be "'develop`""
    }
    It "does NOT corrupt a PowerShell map literal" {
        ConvertFrom-YamlScalarQuoting '@{"a"="b"}' | Should -Be '@{"a"="b"}'
    }
    It "does NOT strip when the interior contains the same quote char" {
        ConvertFrom-YamlScalarQuoting '"a","b"' | Should -Be '"a","b"'
    }
    It "leaves a bare scalar untouched" {
        ConvertFrom-YamlScalarQuoting 'develop' | Should -Be 'develop'
    }
    It "leaves an empty string untouched" {
        ConvertFrom-YamlScalarQuoting '' | Should -Be ''
    }
    It "handles a single quote character without throwing" {
        ConvertFrom-YamlScalarQuoting "'" | Should -Be "'"
    }
    It "passes through non-string input unchanged" {
        ConvertFrom-YamlScalarQuoting $true | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — long-form region resolution learns its prefix vocabulary' {

    It "maps a short locality prefix to the ARM name observed on a sibling stamp" {
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(
                @{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'tr';  ev2RegionName = 'terrawest' }
                @{ stampName = 'trr-02'; stampId = 'trr-02'; clusterType = 'SYNTH'; region = 'tr' }
            ) }
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'TerraRegions' = '{{terraRegions}}' }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        # both stamps carry region 'tr'; 'tr' is a LEARNED prefix for 'terrawest'
        $r.templateParameters['TerraRegions'] | Should -Match 'terrawest'
    }

    It "treats an unrecognised region value as already-ARM rather than dropping it" {
        # No stamp anywhere declares 'aqualand' as a short prefix, so it must pass through.
        $cfg = New-SyntheticConfig -Production @{
            Aqua = @{ stamps = @(
                @{ stampName = 'aq-01'; stampId = 'aq-01'; clusterType = 'SYNTH'; region = 'aqualand' }
            ) }
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'AquaRegions' = '{{aquaRegions}}' }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['AquaRegions'] | Should -Match 'aqualand'
    }

    It "never silently emits an empty region set when stamps exist" {
        $cfg = New-SyntheticConfig -Production @{
            Ember = @{ stamps = @(
                @{ stampName = 'em-01'; stampId = 'em-01'; clusterType = 'SYNTH'; region = 'embernorth' }
                @{ stampName = 'em-02'; stampId = 'em-02'; clusterType = 'SYNTH'; region = 'embersouth' }
            ) }
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'EmberRegions' = '{{emberRegions}}' }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['EmberRegions'] | Should -Match 'embernorth'
        $r.templateParameters['EmberRegions'] | Should -Match 'embersouth'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — deferred cloud blocker (inventory missing clusterType)' {

    It "does NOT throw when the deficient cloud's token is never consumed" {
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
            Aqua  = @{ stamps = @(@{ stampName = 'aq-01';  stampId = 'aq-01' }) }   # no clusterType
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}' }
        { Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg } | Should -Not -Throw
    }

    It "DOES throw INVENTORY_MISSING_CLUSTERTYPE when the deficient cloud's token IS consumed" {
        $cfg = New-SyntheticConfig -Production @{
            Aqua = @{ stamps = @(@{ stampName = 'aq-01'; stampId = 'aq-01' }) }   # no clusterType
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Aquastamps' = '{{aquaStamps}}' }
        { Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg } |
            Should -Throw -ExpectedMessage '*INVENTORY_MISSING_CLUSTERTYPE*'
    }

    It "names the offending cloud and stamp in the failure so an operator can fix it" {
        $cfg = New-SyntheticConfig -Production @{
            Aqua = @{ stamps = @(@{ stampName = 'aq-77'; stampId = 'aq-77' }) }
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Aquastamps' = '{{aquaStamps}}' }
        $msg = ''
        try { Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg } catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'Aqua'
        $msg | Should -Match 'aq-77'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — L2 model/YAML drift drop' {

    It "drops a catalog token the pipeline YAML no longer declares" {
        $declared = @(
            (New-Declared -Name 'Terrastamps' -Default '@()')
            (New-Declared -Name 'KeepMe'      -Default 'yes')
        )
        $cat = New-SyntheticCatalog `
            -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}'; 'KeepMe' = 'yes'; 'RetiredParam' = 'legacy' } `
            -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters.Keys | Should -Not -Contain 'RetiredParam'
        $r.templateParameters.Keys | Should -Contain 'KeepMe'
        @($r.droppedParameters).parameter | Should -Contain 'RetiredParam'
    }

    It "keeps every token when the YAML declares them all" {
        $declared = @((New-Declared -Name 'KeepMe' -Default 'yes'), (New-Declared -Name 'AlsoKeep' -Default 'no'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'KeepMe' = 'yes'; 'AlsoKeep' = 'no' } -DeclaredParameters $declared
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig (New-SyntheticConfig)
        @($r.droppedParameters).Count | Should -Be 0
        $r.templateParameters.Count   | Should -Be 2
    }

    It "does not drop anything when the pipeline has no YAML introspection at all" {
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Anything' = 'value'; 'Another' = 'v2' }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig (New-SyntheticConfig)
        @($r.droppedParameters).Count | Should -Be 0
        $r.templateParameters.Count   | Should -Be 2
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — partition gating' {

    It "emits the DECLARED DEFAULT for params whose partition script flag is false" {
        $declared = @(
            (New-Declared -Name 'AquaScript'  -Type 'boolean' -Default 'false')
            (New-Declared -Name 'Aquastamps'  -Default '@()')
            (New-Declared -Name 'AquaRegions' -Default 'regions()')
        )
        $cat = New-SyntheticCatalog `
            -TemplateParameters @{ 'AquaScript' = 'false'; 'Aquastamps' = '{{aquaStamps}}'; 'AquaRegions' = '{{aquaRegions}}' } `
            -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Aqua = @{ stamps = @(@{ stampName = 'aq-01'; stampId = 'aq-01'; clusterType = 'SYNTH'; region = 'aquanorth' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Aquastamps']  | Should -Be '@()'
        $r.templateParameters['AquaRegions'] | Should -Be 'regions()'
        $r.resolutionSources['Aquastamps']   | Should -Match 'partitionDisabled'
    }

    It "resolves normally when the partition script flag is true" {
        $declared = @(
            (New-Declared -Name 'AquaScript' -Type 'boolean' -Default 'false')
            (New-Declared -Name 'Aquastamps' -Default '@()')
        )
        $cat = New-SyntheticCatalog `
            -TemplateParameters @{ 'AquaScript' = 'true'; 'Aquastamps' = '{{aquaStamps}}' } `
            -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Aqua = @{ stamps = @(@{ stampName = 'aq-01'; stampId = 'aq-01'; clusterType = 'SYNTH'; region = 'aquanorth' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Aquastamps'] | Should -Match 'aq-01'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — learned model supplies values, run context always wins' {

    It "uses the learned value for a stamp list instead of raw inventory" {
        $declared = @((New-Declared -Name 'Terrastamps' -Default '@()'))
        $model = @{ Terrastamps = @{ shape = 'list'; container = '@()'; selectedValue = '@("trr-99")'; selectedFromRunId = 5150 } }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Terrastamps'] | Should -Be '@("trr-99")'
        $r.resolutionSources['Terrastamps']  | Should -Match '^model:'
    }

    It "uses the learned WILDCARD verbatim" {
        $declared = @((New-Declared -Name 'Terrastamps' -Default '@()'))
        $model = @{ Terrastamps = @{ shape = 'wildcard'; selectedValue = '*'; selectedFromRunId = 5150 } }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Terrastamps'] | Should -Be '*'
    }

    It "NEVER lets the model answer for {{currentBranch}} — this release's branch wins" {
        $declared = @((New-Declared -Name 'ArtifactsBranch' -Default 'develop'))
        $model = @{ ArtifactsBranch = @{ shape = 'scalar'; selectedValue = 'releases/ANCIENT'; selectedFromRunId = 1 } }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'ArtifactsBranch' = '{{currentBranch}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig (New-SyntheticConfig) -CurrentBranch 'releases/M9'
        $r.templateParameters['ArtifactsBranch'] | Should -Be 'releases/M9'
        $r.templateParameters['ArtifactsBranch'] | Should -Not -Be 'releases/ANCIENT'
    }

    It "records NO_LEARNED_MODEL as a gap when the pipeline has never been learned from" {
        $declared = @((New-Declared -Name 'Terrastamps' -Default '@()'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}' } -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        ($r.agentGaps -join ' ') | Should -Match 'NO_LEARNED_MODEL'
        # …and still resolves from inventory rather than failing
        $r.templateParameters['Terrastamps'] | Should -Match 'trr-01'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — CCOA exclusions union on top of the learned value' {

    It "adds a CCOA-excluded stamp to the learned exclusion list" {
        $declared = @((New-Declared -Name 'TerraExcludestamps' -Default '@()'))
        $model = @{ TerraExcludestamps = @{ shape = 'list'; container = '@()'; selectedValue = '@("trr-05")'; selectedFromRunId = 5150 } }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'TerraExcludestamps' = '{{excludeStamps}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $cfg = New-SyntheticConfig -CcoaExclusions @{ stamps = @('trr-42') }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['TerraExcludestamps'] | Should -Match 'trr-05'
        $r.templateParameters['TerraExcludestamps'] | Should -Match 'trr-42'
        ($r.agentGaps -join ' ')                    | Should -Match 'CCOA_EXCLUSIONS_ADDED'
    }

    It "leaves the learned exclusion list alone when there are no CCOA exclusions" {
        $declared = @((New-Declared -Name 'TerraExcludestamps' -Default '@()'))
        $model = @{ TerraExcludestamps = @{ shape = 'list'; container = '@()'; selectedValue = '@("trr-05")'; selectedFromRunId = 5150 } }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'TerraExcludestamps' = '{{excludeStamps}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig (New-SyntheticConfig)
        $r.templateParameters['TerraExcludestamps'] | Should -Be '@("trr-05")'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — L4 branch-conditional enum resolution' {

    # The rule is not knowledge this code holds — it is read out of the prose the
    # pipeline author wrote in the parameter's own displayName.
    BeforeAll {
        $script:EnumDisplay = "Branch Prefix for Build (Use 1st option for 'develop/master' branches, 2nd for private branches)"
    }

    It "picks the option the declaration assigns to this branch family" {
        $opts = @('official-prefix', 'private-prefix')
        $pick = Resolve-BranchConditionalEnum -DisplayName $script:EnumDisplay -Values $opts -BranchName 'develop'
        $pick.value   | Should -Be 'official-prefix'
        $pick.ordinal | Should -Be 1
    }

    It "picks the otherwise-case option for a branch the rule does not name" {
        $opts = @('official-prefix', 'private-prefix')
        $pick = Resolve-BranchConditionalEnum -DisplayName $script:EnumDisplay -Values $opts -BranchName 'users/someone/wip'
        $pick.value   | Should -Be 'private-prefix'
        $pick.ordinal | Should -Be 2
    }

    It "matches a leading path segment, not just an exact branch name" {
        $opts = @('official-prefix', 'private-prefix')
        $pick = Resolve-BranchConditionalEnum -DisplayName $script:EnumDisplay -Values $opts -BranchName 'master/hotfix'
        $pick.value | Should -Be 'official-prefix'
    }

    It "returns null when the declaration encodes no branch rule at all" {
        $pick = Resolve-BranchConditionalEnum -DisplayName 'Pick a resource size' -Values @('alpha', 'beta') -BranchName 'develop'
        $pick | Should -BeNullOrEmpty
    }

    It "returns null for an empty option list" {
        Resolve-BranchConditionalEnum -DisplayName $script:EnumDisplay -Values @() -BranchName 'develop' | Should -BeNullOrEmpty
    }

    It "never overrides an explicit owner choice that differs from the declared default" {
        $declared = @((New-Declared -Name 'Resources' -Default 'develop-res' -Values @('develop-res', 'releases-res')))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Resources' = 'OWNER-PINNED' } -DeclaredParameters $declared
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig (New-SyntheticConfig) -CurrentBranch 'releases/M9'
        $r.templateParameters['Resources'] | Should -Be 'OWNER-PINNED'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P3 — L-10 dual gate is wildcard-aware' {

    It "does NOT report EV2_DUAL_GATE_MISALIGNMENT when the stamp list is a wildcard" {
        $declared = @((New-Declared -Name 'Terrastamps' -Default '@()'), (New-Declared -Name 'TerraRegions' -Default 'regions()'), (New-Declared -Name 'TerraExcludestamps' -Default '@()'))
        $model = @{
            Terrastamps  = @{ shape = 'wildcard';    selectedValue = '*';                     selectedFromRunId = 7 }
            TerraRegions = @{ shape = 'regionsList'; container = 'regions'; selectedValue = 'regions(terrawest)'; selectedFromRunId = 7 }
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}'; 'TerraRegions' = '{{terraRegions}}'; 'TerraExcludestamps' = '{{excludeStamps}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(
                @{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }
                @{ stampName = 'trr-09'; stampId = 'trr-09'; clusterType = 'SYNTH'; region = 'terraeast' }
            ) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        ($r.agentGaps -join ' ') | Should -Not -Match 'EV2_DUAL_GATE_MISALIGNMENT'
    }

    It "reports REGION_SCOPED_OUT_STAMPS instead, naming the stamp that gets no action" {
        $declared = @((New-Declared -Name 'Terrastamps' -Default '@()'), (New-Declared -Name 'TerraRegions' -Default 'regions()'), (New-Declared -Name 'TerraExcludestamps' -Default '@()'))
        $model = @{
            Terrastamps  = @{ shape = 'wildcard';    selectedValue = '*';                     selectedFromRunId = 7 }
            TerraRegions = @{ shape = 'regionsList'; container = 'regions'; selectedValue = 'regions(terrawest)'; selectedFromRunId = 7 }
        }
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}'; 'TerraRegions' = '{{terraRegions}}'; 'TerraExcludestamps' = '{{excludeStamps}}' } `
                                    -DeclaredParameters $declared -LearnedModel $model
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(
                @{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }
                @{ stampName = 'trr-09'; stampId = 'trr-09'; clusterType = 'SYNTH'; region = 'terraeast' }
            ) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        ($r.agentGaps -join ' ') | Should -Match 'REGION_SCOPED_OUT_STAMPS'
        ($r.agentGaps -join ' ') | Should -Match 'trr-09'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P4 — Test-ParameterPayload finding classes' {

    BeforeAll {
        $script:Decl = @(
            [pscustomobject]@{ name = 'Terrastamps';  type = 'string'; default = '@()' }
            [pscustomobject]@{ name = 'TerraRegions'; type = 'string'; default = 'regions()' }
        )
        $script:Mdl = [pscustomobject]@{
            Terrastamps  = [pscustomobject]@{ shape = 'list';        container = '@()';       selectedValue = '@("trr-01","trr-02")'; selectedFromRunId = 7 }
            TerraRegions = [pscustomobject]@{ shape = 'regionsList'; container = 'regions'; selectedValue = 'regions(terrawest,terraeast,terranorth)'; selectedFromRunId = 7 }
        }
    }

    It "accepts a payload that agrees with declaration and model" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")'; TerraRegions = 'regions(terrawest,terraeast,terranorth)' }
        (Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl).ok | Should -BeTrue
    }

    It "flags UNDECLARED_PARAMETER" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")'; TerraRegions = 'regions(terrawest,terraeast,terranorth)'; Ghost = 'x' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl
        $r.ok | Should -BeFalse
        @($r.findings).code | Should -Contain 'UNDECLARED_PARAMETER'
    }

    It "flags MISSING_DECLARED_PARAMETER" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl
        $r.ok | Should -BeFalse
        @($r.findings).code | Should -Contain 'MISSING_DECLARED_PARAMETER'
    }

    It "tolerates a missing declared parameter under -AllowMissingDeclared" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl -AllowMissingDeclared
        @($r.findings).code | Should -Not -Contain 'MISSING_DECLARED_PARAMETER'
    }

    It "flags SHAPE_MISMATCH when a regions(...) value degrades to a bare scalar" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")'; TerraRegions = 'terrawest' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl
        $r.ok | Should -BeFalse
        @($r.findings).code | Should -Contain 'SHAPE_MISMATCH'
    }

    It "flags REGION_SET_SHRINK and names the dropped regions" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")'; TerraRegions = 'regions(terrawest)' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl
        $r.ok | Should -BeFalse
        $f = @($r.findings) | Where-Object { $_.code -eq 'REGION_SET_SHRINK' }
        $f | Should -Not -BeNullOrEmpty
        $f.detail | Should -Match 'terraeast'
    }

    It "does NOT flag a region-set GROWTH" {
        $p = @{ Terrastamps = '@("trr-01","trr-02")'; TerraRegions = 'regions(terrawest,terraeast,terranorth,terrasouth)' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl
        @($r.findings).code | Should -Not -Contain 'REGION_SET_SHRINK'
    }

    It "FLAGS a wildcard where the model learned an enumerated list — that is the largest possible scope expansion" {
        $p = @{ Terrastamps = '*'; TerraRegions = 'regions(terrawest,terraeast,terranorth)' }
        $r = Test-ParameterPayload -Payload $p -DeclaredParameters $script:Decl -Model $script:Mdl
        $r.ok | Should -BeFalse
        $f = @($r.findings | Where-Object { $_.parameter -eq 'Terrastamps' -and $_.code -eq 'SHAPE_MISMATCH' })
        $f | Should -Not -BeNullOrEmpty
        $f[0].expected | Should -Match 'list'
    }

    It "checks nothing but still succeeds when neither declaration nor model is supplied" {
        $r = Test-ParameterPayload -Payload @{ Anything = 'goes' }
        $r.ok | Should -BeTrue
        @($r.findings).Count | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P4 — wildcard narrowing is a shape break, graded by model confidence' {

    BeforeAll {
        # A single stamps-style parameter learned as `*`. Narrowing is supposed to be
        # expressed through the matching exclude parameter, never by replacing `*`
        # with an enumeration — so wildcard -> list is a genuine break, not a variant.
        $script:WildDecl = @( [pscustomobject]@{ name = 'Terrastamps'; type = 'string'; default = '*' } )

        function New-WildModel {
            param([string]$Stability, [object]$LowConfidence)
            $e = [ordered]@{ shape = 'wildcard'; container = $null; lastValue = '*'; selectedValue = '*'; selectedFromRunId = 11 }
            if ($PSBoundParameters.ContainsKey('Stability'))     { $e['stability']     = $Stability }
            if ($PSBoundParameters.ContainsKey('LowConfidence')) { $e['lowConfidence'] = $LowConfidence }
            [pscustomobject]@{ Terrastamps = [pscustomobject]$e }
        }
    }

    It "REJECTS an enumerated list where the model learned a constant wildcard" {
        $m = New-WildModel -Stability 'constant'
        $r = Test-ParameterPayload -Payload @{ Terrastamps = '@("trr-01","trr-02")' } -DeclaredParameters $script:WildDecl -Model $m
        $r.ok | Should -BeFalse
        $f = @($r.findings | Where-Object { $_.parameter -eq 'Terrastamps' -and $_.code -eq 'SHAPE_MISMATCH' })
        @($f).Count        | Should -Be 1
        $f[0].severity     | Should -Be 'error'
        $f[0].expected     | Should -Match 'wildcard'
        $f[0].actual       | Should -Match 'list'
    }

    It "DOWNGRADES the same break to a non-blocking warning when the model is lowConfidence" {
        $m = New-WildModel -LowConfidence $true
        $r = Test-ParameterPayload -Payload @{ Terrastamps = '@("trr-01","trr-02")' } -DeclaredParameters $script:WildDecl -Model $m
        $r.ok | Should -BeTrue
        $f = @($r.findings | Where-Object { $_.parameter -eq 'Terrastamps' -and $_.code -eq 'SHAPE_MISMATCH' })
        @($f).Count    | Should -Be 1
        $f[0].severity | Should -Be 'warning'
        $f[0].detail   | Should -Match 'lowConfidence'
    }

    It "DOWNGRADES the break when the learned form is volatile rather than constant" {
        $m = New-WildModel -Stability 'volatile'
        $r = Test-ParameterPayload -Payload @{ Terrastamps = '@("trr-01")' } -DeclaredParameters $script:WildDecl -Model $m
        $r.ok | Should -BeTrue
        (@($r.findings | Where-Object { $_.code -eq 'SHAPE_MISMATCH' })[0]).severity | Should -Be 'warning'
    }

    It "still BLOCKS when stability wins over lowConfidence — a constant form is evidence enough" {
        $m = New-WildModel -Stability 'constant' -LowConfidence $true
        $r = Test-ParameterPayload -Payload @{ Terrastamps = '@("trr-01")' } -DeclaredParameters $script:WildDecl -Model $m
        $r.ok | Should -BeFalse
        (@($r.findings | Where-Object { $_.code -eq 'SHAPE_MISMATCH' })[0]).severity | Should -Be 'error'
    }

    It "passes a wildcard payload against a wildcard model with no findings at all" {
        $m = New-WildModel -Stability 'constant'
        $r = Test-ParameterPayload -Payload @{ Terrastamps = '*' } -DeclaredParameters $script:WildDecl -Model $m
        $r.ok | Should -BeTrue
        @($r.findings).Count | Should -Be 0
    }

    It "REJECTS a wildcard payload where the model learned a constant scalar — that is the largest scope expansion" {
        $decl = @( [pscustomobject]@{ name = 'TerraSdpType'; type = 'string'; default = 'Standard' } )
        $m = [pscustomobject]@{ TerraSdpType = [pscustomobject]@{ shape = 'scalar'; stability = 'constant'; lastValue = 'Standard'; selectedValue = 'Standard' } }
        $r = Test-ParameterPayload -Payload @{ TerraSdpType = '*' } -DeclaredParameters $decl -Model $m
        $r.ok | Should -BeFalse
        (@($r.findings | Where-Object { $_.code -eq 'SHAPE_MISMATCH' })[0]).severity | Should -Be 'error'
    }

    It 'keeps `empty` permissive so a partition switched off via <P>Script=False is not a break' {
        # An off partition legitimately collapses every one of its parameters to an
        # empty container, whatever form the model learned for them.
        $decl = @(
            [pscustomobject]@{ name = 'Terrastamps';        type = 'string'; default = '@()' }
            [pscustomobject]@{ name = 'TerraRegions';       type = 'string'; default = 'regions()' }
            [pscustomobject]@{ name = 'TerraExcludestamps'; type = 'string'; default = '@()' }
        )
        $m = [pscustomobject]@{
            Terrastamps        = [pscustomobject]@{ shape = 'empty'; container = '@()';     stability = 'constant'; lastValue = '@()' }
            TerraRegions       = [pscustomobject]@{ shape = 'empty'; container = 'regions'; stability = 'constant'; lastValue = 'regions()' }
            TerraExcludestamps = [pscustomobject]@{ shape = 'empty'; container = '@()';     stability = 'constant'; lastValue = '@()' }
        }
        foreach ($v in @('*', '@("trr-01","trr-02")', 'regions(terrawest)', 'regions(*)', 'Standard', '@()')) {
            $r = Test-ParameterPayload -Payload @{
                Terrastamps = $v; TerraRegions = $v; TerraExcludestamps = $v
            } -DeclaredParameters $decl -Model $m
            @($r.findings | Where-Object { $_.code -eq 'SHAPE_MISMATCH' -and $_.detail -match 'incompatible' }) |
                Should -BeNullOrEmpty -Because "'$v' against a learned empty must not read as a shape break"
        }
    }

    It "marks every non-shape finding class as a blocking error" {
        $decl = @(
            [pscustomobject]@{ name = 'Terrastamps';  type = 'string'; default = '@()' }
            [pscustomobject]@{ name = 'TerraRegions'; type = 'string'; default = 'regions()' }
        )
        $m = [pscustomobject]@{
            TerraRegions = [pscustomobject]@{ shape = 'regionsList'; container = 'regions'
                                              stability = 'constant'; lowConfidence = $true
                                              selectedValue = 'regions(terrawest,terraeast)'; selectedFromRunId = 11 }
        }
        $r = Test-ParameterPayload -Payload @{ TerraRegions = 'regions(terrawest)'; Ghost = 'x' } -DeclaredParameters $decl -Model $m
        $r.ok | Should -BeFalse
        foreach ($code in 'MISSING_DECLARED_PARAMETER', 'UNDECLARED_PARAMETER', 'REGION_SET_SHRINK') {
            $f = @($r.findings | Where-Object { $_.code -eq $code })
            $f            | Should -Not -BeNullOrEmpty -Because "$code must be raised"
            $f[0].severity | Should -Be 'error'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'P4 — Assert-ParameterPayload gate script' {

    BeforeAll {
        $script:GateDir = Join-Path ([System.IO.Path]::GetTempPath()) "p4gate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:GateDir -Force | Out-Null
        $script:GateCatalog = Join-Path $script:GateDir 'pipeline-catalog.json'
        @{
            canary     = @{}
            production = @{
                'SYNTH-PROD' = @{
                    name = 'Synthetic'; id = 909090
                    yamlIntrospection = @{ parameters = @(
                        @{ name = 'Terrastamps';  type = 'string'; default = '@()' }
                        @{ name = 'TerraRegions'; type = 'string'; default = 'regions()' }
                    ) }
                    _learnedFrom = @{ model = @{
                        Terrastamps  = @{ shape = 'list';        container = '@()';       selectedValue = '@("trr-01")'; selectedFromRunId = 7 }
                        TerraRegions = @{ shape = 'regionsList'; container = 'regions'; selectedValue = 'regions(terrawest,terraeast)'; selectedFromRunId = 7 }
                    } }
                }
            }
            'NO-SOURCE-PIPE' = @{}
        } | ConvertTo-Json -Depth 12 | Set-Content $script:GateCatalog -Encoding UTF8
    }
    AfterAll { Remove-Item $script:GateDir -Recurse -Force -ErrorAction SilentlyContinue }

    It "passes a clean payload resolved from the catalog" {
        $p = @{ Terrastamps = '@("trr-01")'; TerraRegions = 'regions(terrawest,terraeast)' }
        $r = & $script:AssertPath -Payload $p -PipelineKey 'SYNTH-PROD' -Scope production -PipelineCatalogPath $script:GateCatalog
        $r.ok      | Should -BeTrue
        $r.checked | Should -BeTrue
    }

    It "THROWS PARAMETER_PAYLOAD_REJECTED on an undeclared parameter" {
        $p = @{ Terrastamps = '@("trr-01")'; TerraRegions = 'regions(terrawest,terraeast)'; Ghost = 'x' }
        { & $script:AssertPath -Payload $p -PipelineKey 'SYNTH-PROD' -Scope production -PipelineCatalogPath $script:GateCatalog } |
            Should -Throw -ExpectedMessage '*PARAMETER_PAYLOAD_REJECTED*'
    }

    It "THROWS on a region-set shrink" {
        $p = @{ Terrastamps = '@("trr-01")'; TerraRegions = 'regions(terrawest)' }
        { & $script:AssertPath -Payload $p -PipelineKey 'SYNTH-PROD' -Scope production -PipelineCatalogPath $script:GateCatalog } |
            Should -Throw -ExpectedMessage '*REGION_SET_SHRINK*'
    }

    It "THROWS on a shape break" {
        $p = @{ Terrastamps = '@("trr-01")'; TerraRegions = 'terrawest' }
        { & $script:AssertPath -Payload $p -PipelineKey 'SYNTH-PROD' -Scope production -PipelineCatalogPath $script:GateCatalog } |
            Should -Throw -ExpectedMessage '*SHAPE_MISMATCH*'
    }

    It "does NOT throw under -WarnOnly, but still reports not-ok" {
        $p = @{ Terrastamps = '@("trr-01")'; TerraRegions = 'regions(terrawest)' }
        $r = & $script:AssertPath -Payload $p -PipelineKey 'SYNTH-PROD' -Scope production -PipelineCatalogPath $script:GateCatalog -WarnOnly -WarningAction SilentlyContinue
        $r.ok | Should -BeFalse
    }

    It "THROWS on a wildcard narrowed to an enumerated list when the model calls that form constant" {
        $decl = @( [pscustomobject]@{ name = 'Terrastamps'; type = 'string'; default = '*' } )
        $mdl  = [pscustomobject]@{ Terrastamps = [pscustomobject]@{ shape = 'wildcard'; stability = 'constant'; lastValue = '*'; selectedValue = '*' } }
        { & $script:AssertPath -Payload @{ Terrastamps = '@("trr-01","trr-02")' } -PipelineKey 'SYNTH-PROD' -Scope production `
                               -DeclaredParameters $decl -Model $mdl } |
            Should -Throw -ExpectedMessage '*SHAPE_MISMATCH*'
    }

    It "WARNS instead of throwing on the same narrowing when the model is lowConfidence, and keeps the finding" {
        $decl = @( [pscustomobject]@{ name = 'Terrastamps'; type = 'string'; default = '*' } )
        $mdl  = [pscustomobject]@{ Terrastamps = [pscustomobject]@{ shape = 'wildcard'; lowConfidence = $true; lastValue = '*'; selectedValue = '*' } }
        $warn = @()
        $r = & $script:AssertPath -Payload @{ Terrastamps = '@("trr-01","trr-02")' } -PipelineKey 'SYNTH-PROD' -Scope production `
                                  -DeclaredParameters $decl -Model $mdl -WarningVariable warn -WarningAction SilentlyContinue
        $r.ok      | Should -BeTrue
        $r.checked | Should -BeTrue
        $r.reason  | Should -Match 'warning'
        # The warning is never silently dropped: it is both printed and returned.
        (@($warn) -join "`n") | Should -Match 'PARAMETER_PAYLOAD_WARNINGS'
        $f = @($r.findings | Where-Object { $_.code -eq 'SHAPE_MISMATCH' })
        @($f).Count    | Should -Be 1
        $f[0].severity | Should -Be 'warning'
    }

    It "degrades gracefully to NO_VALIDATION_SOURCE when the pipeline has neither YAML nor model" {
        $p = @{ Whatever = 'x' }
        $r = & $script:AssertPath -Payload $p -PipelineKey 'NOT-IN-CATALOG' -Scope production -PipelineCatalogPath $script:GateCatalog -WarningAction SilentlyContinue
        $r.checked | Should -BeFalse
        $r.reason  | Should -Match 'NO_VALIDATION_SOURCE'
    }

    It "never blocks a run just because the catalog file is absent" {
        $p = @{ Whatever = 'x' }
        $r = & $script:AssertPath -Payload $p -PipelineKey 'SYNTH-PROD' -Scope production -PipelineCatalogPath (Join-Path $script:GateDir 'does-not-exist.json') -WarningAction SilentlyContinue
        $r.checked | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Genericity — nothing is bound to the onboarded service' {

    It "resolves a service whose clouds are named Terra/Aqua/Ember with no code change" {
        $declared = @(
            (New-Declared -Name 'Terrastamps'  -Default '@()')
            (New-Declared -Name 'Aquastamps'   -Default '@()')
            (New-Declared -Name 'Emberstamps'  -Default '@()')
        )
        $cat = New-SyntheticCatalog -TemplateParameters @{
            'Terrastamps' = '{{terraStamps}}'; 'Aquastamps' = '{{aquaStamps}}'; 'Emberstamps' = '{{emberStamps}}'
        } -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Terra = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
            Aqua  = @{ stamps = @(@{ stampName = 'aq-01';  stampId = 'aq-01';  clusterType = 'SYNTH'; region = 'aquanorth' }) }
            Ember = @{ stamps = @(@{ stampName = 'em-01';  stampId = 'em-01';  clusterType = 'SYNTH'; region = 'embersouth' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Terrastamps'] | Should -Match 'trr-01'
        $r.templateParameters['Aquastamps']  | Should -Match 'aq-01'
        $r.templateParameters['Emberstamps'] | Should -Match 'em-01'
    }

    It "honours an explicit inventory.cloudTokenMap alias" {
        $declared = @((New-Declared -Name 'Zstamps' -Default '@()'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Zstamps' = '{{zStamps}}' } -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Zephyr = @{ stamps = @(@{ stampName = 'zp-01'; stampId = 'zp-01'; clusterType = 'SYNTH'; region = 'zephyrwest' }) }
        } -Extra @{ cloudTokenMap = @{ z = 'Zephyr' } }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Zstamps'] | Should -Match 'zp-01'
    }

    It "honours a per-cloud tokenPrefix declared on the cloud object" {
        $declared = @((New-Declared -Name 'Qstamps' -Default '@()'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Qstamps' = '{{qStamps}}' } -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            Quasar = @{ tokenPrefix = 'q'; stamps = @(@{ stampName = 'qs-01'; stampId = 'qs-01'; clusterType = 'SYNTH'; region = 'quasarnorth' }) }
        }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Qstamps'] | Should -Match 'qs-01'
    }

    It "ignores non-cloud properties sitting alongside clouds in inventory.production" {
        $declared = @((New-Declared -Name 'Terrastamps' -Default '@()'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Terrastamps' = '{{terraStamps}}' } -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            approvalRequired = $true
            cloudsActive     = @('Terra')
            Terra            = @{ stamps = @(@{ stampName = 'trr-01'; stampId = 'trr-01'; clusterType = 'SYNTH'; region = 'terrawest' }) }
        }
        { Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg } | Should -Not -Throw
    }
}

# ============================================================================
# P3 — facet pairing tolerates an author's truncated partition spelling
# ============================================================================
# A safety gate that needs two facets must still find them when the pipeline
# author spelled one of them short (`PubRegions` + `PublicExcludestamps`) and
# declared no head facet to anchor the alias. Nothing below names a real cloud.
Describe 'P3 — Get-PartitionFacetPairs' {

    It 'pairs two facets that share an exact partition name' {
        $p = Get-PartitionFacetPairs -ParameterNames @('TerraRegions','TerraExcludestamps') -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count            | Should -Be 1
        $p[0].partition        | Should -Be 'Terra'
        $p[0].a.name           | Should -Be 'TerraRegions'
        $p[0].b.name           | Should -Be 'TerraExcludestamps'
        @($p[0].aliases).Count | Should -Be 0
    }

    It 'pairs a truncated spelling with its longer partner and reports the long name' {
        $p = Get-PartitionFacetPairs -ParameterNames @('TerRegions','TerraExcludestamps') -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count      | Should -Be 1
        $p[0].partition  | Should -Be 'Terra'
        $p[0].aliases    | Should -Contain 'Ter'
    }

    It 'does not pair partitions that are not prefix-compatible' {
        $p = Get-PartitionFacetPairs -ParameterNames @('TerraRegions','AquaExcludestamps') -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count | Should -Be 0
    }

    It 'prefers the closest spelling when several extensions share a prefix' {
        $p = Get-PartitionFacetPairs -ParameterNames @('TerRegions','TerraExcludestamps','TerraformingExcludestamps') `
                                     -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count     | Should -Be 1
        $p[0].partition | Should -Be 'Terra'
    }

    It 'emits one pair per distinct partition' {
        $p = Get-PartitionFacetPairs -ParameterNames @('TerraRegions','TerraExcludestamps','AquaRegions','AquaExcludestamps') `
                                     -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count | Should -Be 2
        @($p | ForEach-Object { $_.partition }) | Should -Contain 'Terra'
        @($p | ForEach-Object { $_.partition }) | Should -Contain 'Aqua'
    }

    It 'returns nothing when only one side of the pair is present' {
        $p = Get-PartitionFacetPairs -ParameterNames @('TerraRegions') -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count | Should -Be 0
    }

    It 'tolerates an empty parameter list without throwing' {
        { Get-PartitionFacetPairs -ParameterNames @() -FacetA 'Regions' -FacetB 'Excludestamps' } | Should -Not -Throw
    }

    It 'ignores a flat (partition-less) facet name' {
        $p = Get-PartitionFacetPairs -ParameterNames @('Regions','Excludestamps') -FacetA 'Regions' -FacetB 'Excludestamps'
        @($p).Count | Should -Be 0
    }
}

# ============================================================================
# Genericity — the built-in sovereign-cloud aliases are fully replaceable
# ============================================================================
Describe 'Genericity — inventory.defaultCloudAliases replaces the built-in table' {

    It 'lets a service suppress the built-in aliases entirely' {
        $declared = @((New-Declared -Name 'Pubstamps' -Default '@()'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Pubstamps' = '{{pubStamps}}' } -DeclaredParameters $declared
        # 'pub' would resolve via the built-in alias table; an empty override must
        # remove that path, leaving the token unresolvable rather than guessing.
        $cfg = New-SyntheticConfig -Production @{
            cloudsActive = @('Terra')
            Terra        = @{ stamps = @(@{ stampName='trr-01'; stampId='trr-01'; clusterType='SYNTH'; region='terrawest' }) }
        } -Extra @{ defaultCloudAliases = @{} }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        # No cloud named Public/Pub exists and the alias was removed, so nothing
        # may be silently substituted from an unrelated cloud.
        $r.templateParameters['Pubstamps'] | Should -Not -Match 'trr-01'
    }

    It 'lets a service redirect a built-in alias to its own cloud' {
        $declared = @((New-Declared -Name 'Pubstamps' -Default '@()'))
        $cat = New-SyntheticCatalog -TemplateParameters @{ 'Pubstamps' = '{{pubStamps}}' } -DeclaredParameters $declared
        $cfg = New-SyntheticConfig -Production @{
            cloudsActive = @('Terra')
            Terra        = @{ stamps = @(@{ stampName='trr-01'; stampId='trr-01'; clusterType='SYNTH'; region='terrawest' }) }
        } -Extra @{ defaultCloudAliases = @{ pub = 'Terra' } }
        $r = Invoke-SynthResolver -Catalog $cat -ServiceConfig $cfg
        $r.templateParameters['Pubstamps'] | Should -Match 'trr-01'
    }
}

Describe 'Genericity — Get-FacetParameterNames replaces hardcoded partition parameter names' {

    It 'finds the regions facet under any partition spelling' {
        $n = Get-FacetParameterNames -ParameterNames @(
            'TerraRegions','AquaRegions','EmberScript','Emberstamps','BranchPrefix') -Facet 'Regions'
        $n | Should -Contain 'TerraRegions'
        $n | Should -Contain 'AquaRegions'
        $n.Count | Should -Be 2
    }

    It 'finds a flat-scope Regions parameter' {
        $n = Get-FacetParameterNames -ParameterNames @('Regions','stamps','Script') -Facet 'Regions'
        @($n) | Should -Be @('Regions')
    }

    It 'returns partitioned names before the flat name' {
        $n = Get-FacetParameterNames -ParameterNames @('Regions','TerraRegions') -Facet 'Regions'
        $n[0] | Should -Be 'TerraRegions'
        $n[1] | Should -Be 'Regions'
    }

    It 'does not confuse ExcludeRegions with Regions' {
        $r = Get-FacetParameterNames -ParameterNames @('TerraRegions','TerraExcludeRegions') -Facet 'Regions'
        $x = Get-FacetParameterNames -ParameterNames @('TerraRegions','TerraExcludeRegions') -Facet 'ExcludeRegions'
        @($r) | Should -Be @('TerraRegions')
        @($x) | Should -Be @('TerraExcludeRegions')
    }

    It 'includes a partition that owns only the one facet (under-inclusion is the unsafe direction)' {
        # Get-ParameterPartitionModel would refuse to qualify a single-facet candidate;
        # a coverage union must still see it or it silently under-reports.
        $n = Get-FacetParameterNames -ParameterNames @('QuasarRegions') -Facet 'Regions'
        @($n) | Should -Be @('QuasarRegions')
    }

    It 'ignores names that merely end in the facet without an identifier partition' {
        $n = Get-FacetParameterNames -ParameterNames @('  Regions','9Regions','-Regions') -Facet 'Regions'
        $n | Should -Not -Contain '9Regions'
        $n | Should -Not -Contain '-Regions'
    }

    It 'returns nothing when no parameter carries the facet' {
        @(Get-FacetParameterNames -ParameterNames @('BranchPrefix','BuildId') -Facet 'Regions').Count |
            Should -Be 0
    }

    It 'tolerates an empty parameter list' {
        @(Get-FacetParameterNames -ParameterNames @() -Facet 'Regions').Count | Should -Be 0
    }
}

Describe 'Harvested validation-run bug fixes (iteration 6)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
        $script:Kql      = Join-Path $script:RepoRoot '.github\skills\zed-agent\queries\bvt-prot-failures.kql'
        $script:Watcher  = Join-Path $script:RepoRoot '.github\skills\zed-agent\scripts\Register-WatcherTask.ps1'
    }

    Context 'Learning baf9149650df — BVT query must not wrap the time placeholder' {
        It 'does not wrap {{PIPELINE_TRIGGER_TIME}} in datetime()' {
            # datetime(ago(48h)) is a Kusto syntax error. The substituted value must
            # carry its own wrapper so relative expressions stay legal.
            $body = Get-Content $script:Kql -Raw
            $body | Should -Not -Match 'datetime\(\s*\{\{PIPELINE_TRIGGER_TIME\}\}'
        }

        It 'still contains the placeholder, used bare' {
            $body = Get-Content $script:Kql -Raw
            $body | Should -Match '\{\{PIPELINE_TRIGGER_TIME\}\}'
            $body | Should -Match 'let triggerTime = \{\{PIPELINE_TRIGGER_TIME\}\};'
        }

        It 'documents that the agent must emit the wrapper' {
            $body = Get-Content $script:Kql -Raw
            $body | Should -Match 'ago\(48h\)'
            $body | Should -Match 'datetime\(ago\(48h\)\) is a Kusto syntax error'
        }
    }

    Context 'Learning 16c8ad61f5f3 — teardown must not kill its own shell' {
        It 'excludes the current process and its ancestors from the kill set' {
            $body = Get-Content $script:Watcher -Raw
            $body | Should -Match '\$selfChain'
            $body | Should -Match 'selfChain\.Contains\(\$_\.Id\)'
            $body | Should -Match 'ParentProcessId'
        }

        It 'no longer uses the over-broad *zed-agent*watcher* command-line glob' {
            # That glob matched any pwsh launched from a zed-agent path — including
            # the shell running the cleanup itself.
            $body = Get-Content $script:Watcher -Raw
            $body | Should -Not -Match '\*zed-agent\*watcher\*'
        }

        It 'still matches the real watcher entry script' {
            $body = Get-Content $script:Watcher -Raw
            $body | Should -Match '\*Release-Watcher\*'
        }

        It 'the self-PID walk is bounded so a cyclic parent chain cannot hang teardown' {
            $body = Get-Content $script:Watcher -Raw
            $body | Should -Match '\$guard -lt \d+'
        }
    }
}

Describe 'Service-agnostic configuration surface (learning 5df310a7c910)' {
    BeforeAll {
        $script:AhRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
        $script:AhInv   = Get-Content (Join-Path $script:AhRoot '.github\skills\zed-agent\scripts\Get-StampInventory.ps1') -Raw
        $script:AhGeo   = Get-Content (Join-Path $script:AhRoot '.github\skills\zed-agent\scripts\Assert-GeographyCoverage.ps1') -Raw
    }

    Context 'Get-StampInventory.ps1 defaults are overridable, not baked in' {
        It 'reads the sovereign-cloud set from service-config' {
            $script:AhInv | Should -Match "inventory\.PSObject\.Properties\['sovereignClouds'\]"
        }
        It 'reads the cluster-type substring table from service-config' {
            $script:AhInv | Should -Match "inventory\.PSObject\.Properties\['clusterTypeSubstrings'\]"
        }
        It 'reads the default commercial cloud name from service-config' {
            $script:AhInv | Should -Match "inventory\.PSObject\.Properties\['defaultCommercialCloud'\]"
        }
        It 'no longer hardcodes the commercial cloud at the SDS reconcile call site' {
            $script:AhInv | Should -Match '\$sdsCloudForReconcile\s*=.*\$defaultCommercialCloud'
        }
        It "keeps exactly one literal 'Public' - the documented fallback default" {
            $m = [regex]::Matches($script:AhInv, "'Public'")
            $m.Count | Should -Be 1
        }
    }

    Context 'Cluster-type resolution is defined once, not duplicated' {
        It 'exposes a single Resolve-RowClusterType helper' {
            ([regex]::Matches($script:AhInv, 'function\s+Resolve-RowClusterType')).Count | Should -Be 1
        }
        It 'is an advanced function so a mistyped parameter cannot be silently swallowed' {
            $script:AhInv | Should -Match "(?s)function\s+Resolve-RowClusterType.{0,1500}?\[CmdletBinding\(\)\]"
        }
        It 'declares the fallback substring literals in exactly one place' {
            ([regex]::Matches($script:AhInv, "match\s*=\s*'-sfmc'")).Count | Should -Be 1
        }
        It 'uses ::new() rather than New-Object for generic collections' {
            $script:AhInv | Should -Not -Match 'New-Object\s+System\.Collections\.Generic'
        }
    }

    Context 'Assert-GeographyCoverage.ps1 names discovered parameters, not fixed ones' {
        It 'collects the region parameter names it actually discovered' {
            $script:AhGeo | Should -Match '\$discoveredRegionParams'
        }
        It 'builds the coverage-gap remedy from those discovered names' {
            # $remedyParam is derived from the discovered set, then interpolated
            # into the GEOGRAPHY_COVERAGE_GAP remedy line.
            $script:AhGeo | Should -Match '(?s)\$remedyParam\s*=\s*if\s*\(\s*\$discoveredRegionParams\.Count'
            $script:AhGeo | Should -Match 'Remedy:.*\$remedyParam parameter'
        }

        It 'falls back to a generic phrase when nothing was discovered' {
            $script:AhGeo | Should -Match "the pipeline's regions parameter"
        }

        It 'carries no service-specific region parameter outside comment-based help' {
            # Strip <# ... #> help blocks and line comments, then assert on code only.
            $code = [regex]::Replace($script:AhGeo, '(?s)<#.*?#>', '')
            $code = ($code -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
            $code | Should -Not -Match 'PubRegions'
        }
    }
}
