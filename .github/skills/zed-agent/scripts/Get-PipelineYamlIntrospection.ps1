<#
.SYNOPSIS
    Static-analyses an Azure Pipelines YAML and returns a structured summary
    of cloud coverage, stamp/region defaults, EV2 task settings, and SDS hints.

.DESCRIPTION
    Tier 1 of the YAML+SDS inventory mechanism (Phase 11.4a).

    Reads YAML from disk (or stdin via -Content) and extracts everything
    setup-service needs to populate pipeline-catalog.json → yamlIntrospection:

      * Pipeline `parameters:` (shared line-walker — see lib/YamlParamModel.ps1).
      * Cloud convention — two known patterns:
          stageHardcoded     : stage-scope `value: <CloudName>` under a `cloud`
                               variable (one pipeline = one cloud).
          perCloudScriptFlags: per-partition `<Prefix>Script` parameters gated by
                               `${{ if eq(parameters.<Prefix>Script, true) }}`
                               (one pipeline → many clouds).
      * Stamp/region defaults, derived from the GENERIC quad regex
        `^(?<partition>.*?)(Script|stamps|Excludestamps|Regions|ExcludeRegions)$`:
          flat               : empty partition (`stamps`, `Regions`, …).
          perCloud           : non-empty partition (`<Prefix>stamps`, …).
        Partition names are DISCOVERED, never hard-coded.
      * EV2 task input block (vsrm-ev2.ev2-rollout.ev2-rollout-task.Ev2RARollout@N).
      * SDS filename + likely source-repo path, extracted from any inline
        PowerShell `-SdsFiles <file>` argument plus the closest preceding
        `$hsp_source = "$(Pipeline.Workspace)/s/dep_specs/<path>"` variable.
      * Self-repo + base branch from `resources.repositories[]` (type git, ref
        refs/heads/<branch>, name <Project>/<RepoName>).

    The result is a snapshot — no network, no auth, no side effects. Setup-service
    persists it under pipeline-catalog.json → pipelines.<key>.yamlIntrospection
    after confirming with the owner.

.PARAMETER YamlPath
    Absolute path to the YAML file. Required unless -Content is supplied.

.PARAMETER Content
    Raw YAML text. Overrides -YamlPath when both are given.

.PARAMETER SourceLabel
    Provenance string recorded in the `source` field when analysing -Content.
    Callers that fetch YAML over the network MUST pass the real origin (e.g.
    the ADO preview endpoint URI) so the catalog never carries a path from a
    machine that is not this one.

.PARAMETER AllowEmptyParameters
    Escape hatch for pipelines that genuinely declare no `parameters:` block.
    Without it, an empty extraction is a hard error — a silent no-op that
    writes `null` into the catalog is the exact failure mode this guards.

.PARAMETER CloudNames
    Vocabulary used by the stage-hardcoded detector ONLY: a `- name: cloud` /
    `value: X` pair counts as a cloud declaration when X is in this list. It is
    a disambiguator for one narrow heuristic, not the source of ZED's partition
    discovery — that is derived generically from the parameter names themselves
    (Get-ParameterPartitionModel). Services whose YAML names its environments
    differently override it from service-config.json → `cloudNames`.

.OUTPUTS
    PSCustomObject — see DESCRIPTION above for fields.
#>
[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Path')][string]$YamlPath,
    [Parameter(Mandatory=$true, ParameterSetName='Content')][string]$Content,
    [Parameter(ParameterSetName='Content')][string]$SourceLabel,
    [switch]$AllowEmptyParameters,
    [string[]]$CloudNames
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\YamlParamModel.ps1')

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw "YAML file not found: $YamlPath"
    }
    $yaml = Get-Content -LiteralPath $YamlPath -Raw
    $source = (Resolve-Path -LiteralPath $YamlPath).Path
} else {
    $yaml = $Content
    $source = if ($SourceLabel) { $SourceLabel } else { '<inline>' }
}

# Strip CRs for predictable regex behaviour.
$yaml = $yaml -replace "`r",''

# Vocabulary for the stage-hardcoded detector only (see -CloudNames). Every
# other cloud/partition fact ZED uses is derived from the YAML itself; this list
# just decides whether a literal `- name: cloud / value: X` pair is naming a
# deployment cloud or something else. Overridable per service.
$knownClouds = if ($PSBoundParameters.ContainsKey('CloudNames') -and @($CloudNames).Count -gt 0) {
    @($CloudNames)
} else {
    @('Public','Canary','Fairfax','Mooncake','USNat','USSec','Bleu','BVTD3','EXP')
}

function Get-Param-Block {
    # Delegates to the shared, indentation-tolerant walker so that this script
    # and Read-PipelineYaml.ps1 can never diverge.
    param([string]$Text)
    return @(Get-YamlParameterBlock -Yaml $Text)
}

function Get-Stage-Hardcoded-Cloud {
    param([string]$Text)
    # Look for `- name: cloud` followed (within ~4 lines) by `value: <Cloud>`.
    $clouds = New-Object System.Collections.Generic.HashSet[string]
    $rx = '(?ms)-\s*name\s*:\s*cloud\s*\n\s*value\s*:\s*([A-Za-z0-9]+)'
    foreach ($m in [regex]::Matches($Text, $rx)) {
        $val = $m.Groups[1].Value
        if ($knownClouds -contains $val) { [void]$clouds.Add($val) }
    }
    return @($clouds)
}

function Get-PerCloud-ScriptFlags {
    param([object[]]$Params)
    $prefixes = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $Params) {
        if ($p.name -match '^([A-Z][A-Za-z0-9]*)Script$' -and $p.type -eq 'boolean') {
            [void]$prefixes.Add($Matches[1])
        }
    }
    return @($prefixes)
}

function Resolve-FacetDefaults {
    # Turn a facet -> parameterName map into a facet -> declared-default map.
    param([object]$Facets, [hashtable]$DefaultsByName)
    $entry = [ordered]@{
        stamps         = $null
        excludeStamps  = $null
        regions        = $null
        excludeRegions = $null
        script         = $null
    }
    $paramNames = [ordered]@{}
    if ($Facets) {
        foreach ($f in $Facets.PSObject.Properties) {
            $paramNames[$f.Name] = $f.Value
            if ($entry.Contains($f.Name)) { $entry[$f.Name] = $DefaultsByName[$f.Value] }
            else { $entry[$f.Name] = $DefaultsByName[$f.Value] }
        }
    }
    $entry['_parameterNames'] = [pscustomobject]$paramNames
    return [pscustomobject]$entry
}

function Get-Ev2-Task {
    param([string]$Text)
    # Find the first Ev2RARollout task input block. Capture indented `inputs:` keys.
    $rx = '(?ms)-\s*task\s*:\s*[^\n]*Ev2RARollout@(\d+)\s*\n(?:[^\n]*\n)*?\s*inputs\s*:\s*\n((?:\s{4,}.+\n)+)'
    $m = [regex]::Match($Text, $rx)
    if (-not $m.Success) { return $null }
    $version = $m.Groups[1].Value
    $body = $m.Groups[2].Value
    $kv = @{}
    foreach ($line in ($body -split "`n")) {
        if ($line -match '^\s+([A-Za-z][A-Za-z0-9]*)\s*:\s*(.+?)\s*$') {
            $kv[$Matches[1]] = $Matches[2].Trim("'`"")
        }
    }
    return [pscustomobject]@{
        taskVersion                = [int]$version
        stageMapName               = $kv['StageMapName']
        stageMapVersion            = $kv['StageMapVersion']
        endpointProviderType       = $kv['EndpointProviderType']
        approvalServiceEnvironment = $kv['ApprovalServiceEnvironment']
        connectedServiceName       = $kv['ConnectedServiceName']
        serviceRootPath            = $kv['ServiceRootPath']
        rolloutSpecPath            = $kv['RolloutSpecPath']
        select                     = $kv['Select']
        useServerMonitorTask       = $kv['UseServerMonitorTask']
    }
}

function Get-Sds-Hint {
    param([string]$Text)
    # `-SdsFiles <file>` is what `New-RegionAgnosticArtifacts` reads.
    $rxFile = '(?im)-SdsFiles\s+([^\s,;|]+)'
    $m = [regex]::Match($Text, $rxFile)
    if (-not $m.Success) { return $null }
    $fileName = [System.IO.Path]::GetFileName($m.Groups[1].Value)

    # Look for any quoted string literal that references a `dep_specs/<repoPath>`
    # subtree. The DataMover convention uses `$hsp_source = "$(Pipeline.Workspace)/s/dep_specs/..."`
    # but other services use different variable names (e.g. `$sds_source`,
    # `$specsRoot`), inline `Copy-Item` calls, or no variable at all. Be permissive:
    # accept any quoted path containing `dep_specs/`, with or without a preceding
    # PowerShell variable assignment, and either `/` or `\` separators.
    $repoPath = $null
    $sourceTag = 'regex:-SdsFiles'
    $candidates = @(
        # (a) Variable assignment: $anyName = "...dep_specs/<path>"
        @{ rx = '(?im)\$\w+\s*=\s*"[^"]*?[\\/]dep_specs[\\/]([^"\s]+)"'; tag = 'regex:-SdsFiles + $var=dep_specs' },
        # (b) Bare quoted literal anywhere: "...dep_specs/<path>"
        @{ rx = '(?im)"[^"]*?[\\/]dep_specs[\\/]([^"\s]+)"';              tag = 'regex:-SdsFiles + dep_specs-literal' }
    )
    foreach ($c in $candidates) {
        $mp = [regex]::Match($Text, $c.rx)
        if ($mp.Success) {
            $repoPath = $mp.Groups[1].Value.TrimEnd('/','\').Replace('\','/')
            $sourceTag = $c.tag
            break
        }
    }
    # NOTE: repoPath is deliberately the *directory* only. setup-service Phase 4.5
    # consumes fileName and repoPath separately (repoPath to locate the subtree,
    # fileName as a Get-ChildItem -Filter), so appending the file name here would
    # break that contract.
    return [pscustomobject]@{
        fileName = $fileName
        repoPath = $repoPath
        source   = $sourceTag
    }
}

function Get-Self-Repo {
    param([string]$Text)
    # resources.repositories:
    #   - repository: dep_specs
    #     type: git
    #     ref: refs/heads/develop
    #     name: One/Mgmt-RecoverySvcs-DataMover
    $rxBlock = '(?ms)resources\s*:\s*\n\s+repositories\s*:\s*\n((?:\s+-\s+repository[\s\S]+?)(?=\n[A-Za-z]|\z))'
    $blockMatch = [regex]::Match($Text, $rxBlock)
    if (-not $blockMatch.Success) { return $null }
    $block = $blockMatch.Groups[1].Value
    $entries = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($line in ($block -split "`n")) {
        if ($line -match '^\s*-\s*repository\s*:\s*(.+)$') {
            if ($cur) { $entries.Add([pscustomobject]$cur) | Out-Null }
            $cur = @{ alias = $Matches[1].Trim().Trim("'`""); type=$null; name=$null; branch=$null }
        } elseif ($cur -and $line -match '^\s+(type|name|ref)\s*:\s*(.+)$') {
            $k = $Matches[1]; $v = $Matches[2].Trim().Trim("'`"")
            if ($k -eq 'type') { $cur.type = $v }
            if ($k -eq 'name') { $cur.name = $v }
            if ($k -eq 'ref')  {
                if ($v -match '^refs/heads/(.+)$') { $cur.branch = $Matches[1] } else { $cur.branch = $v }
            }
        }
    }
    if ($cur) { $entries.Add([pscustomobject]$cur) | Out-Null }

    # Heuristic: the self-repo is the git entry whose alias is `self`, `dep_specs`,
    # or `source`; else the first git entry whose name does not start with
    # `OneBranch.Pipelines/`.
    $candidates = $entries | Where-Object { $_.type -eq 'git' -and $_.name -and $_.name -notmatch '^OneBranch\.Pipelines/' }
    $self = $candidates | Where-Object { $_.alias -in @('self','dep_specs','source','sourceRepo') } | Select-Object -First 1
    if (-not $self -and $candidates.Count -gt 0) { $self = $candidates[0] }
    if (-not $self) { return $null }
    $repoName = $self.name
    if ($repoName -match '/') { $repoName = ($repoName -split '/')[-1] }
    return [pscustomobject]@{
        alias      = $self.alias
        name       = $repoName
        fullName   = $self.name
        baseBranch = $self.branch
    }
}

function Get-Pipeline-Header {
    param([string]$Text)
    $name = $null; $trigger = $null
    if ($Text -match '(?m)^name\s*:\s*(.+)$') { $name = $Matches[1].Trim().Trim("'`"") }
    if ($Text -match '(?m)^trigger\s*:\s*(\S+)\s*$') { $trigger = $Matches[1] }
    [pscustomobject]@{ name = $name; trigger = $trigger }
}

# ── Extract ────────────────────────────────────────────────────────────
$header  = Get-Pipeline-Header -Text $yaml
$params  = @(Get-Param-Block   -Text $yaml)

# A silent empty extraction is the failure mode that poisoned the catalog with
# `parameters: null` and forced a fallback to hand-seeded guesses. Fail loudly.
if ($params.Count -eq 0 -and -not $AllowEmptyParameters) {
    $hasBlock = $yaml -match '(?m)^parameters\s*:\s*$'
    $why = if ($hasBlock) {
        "a top-level 'parameters:' block IS present but no '- name:' entries could be read from it (unexpected indentation or formatting)"
    } else {
        "no top-level 'parameters:' block was found"
    }
    throw ("YAML parameter extraction yielded 0 parameters from '$source': $why. " +
           "Refusing to write a null parameter surface — the catalog would silently fall back to hand-seeded values. " +
           "Verify the YAML is the fully-resolved pipeline definition (the ADO /pipelines/{id}/preview endpoint returns one), " +
           "or pass -AllowEmptyParameters if this pipeline genuinely declares no parameters.")
}

$defaultsByName = @{}
foreach ($p in $params) { $defaultsByName[[string]$p.name] = $p.default }

$hard      = Get-Stage-Hardcoded-Cloud -Text $yaml
$flags     = Get-PerCloud-ScriptFlags  -Params $params
$partModel = Get-ParameterPartitionModel -ParameterNames @($params | ForEach-Object { [string]$_.name })

$cloudConvention = 'unknown'
$cloudsDetected  = @()
$stampParamShape = 'flat'
$perCloud        = $null
$flatDefaults    = $null

if ($partModel.partitions.Count -gt 0) {
    # Partitions discovered from the declared parameter names — the authoritative
    # signal. `<P>Script` flags corroborate it but are not required.
    $cloudConvention = if ($flags.Count -gt 0) { 'perCloudScriptFlags' } else { 'perCloudParameters' }
    $cloudsDetected  = @($partModel.partitions | ForEach-Object { $_.name })
    $stampParamShape = 'perCloud'
    $pc = [ordered]@{}
    foreach ($part in $partModel.partitions) {
        $pc[$part.name] = Resolve-FacetDefaults -Facets $part.facets -DefaultsByName $defaultsByName
    }
    $perCloud = [pscustomobject]$pc
    if (@($partModel.flat.PSObject.Properties).Count -gt 0) {
        $flatDefaults = Resolve-FacetDefaults -Facets $partModel.flat -DefaultsByName $defaultsByName
    }
} elseif ($hard.Count -gt 0) {
    $cloudConvention = 'stageHardcoded'
    $cloudsDetected  = @($hard)
    $stampParamShape = 'flat'
    $flatDefaults    = Resolve-FacetDefaults -Facets $partModel.flat -DefaultsByName $defaultsByName
} else {
    # No detectable convention — still surface the flat extraction so the owner
    # has data to confirm.
    $flatDefaults = Resolve-FacetDefaults -Facets $partModel.flat -DefaultsByName $defaultsByName
}

# Datacenter type (ACTIVE / PASSIVE / both) — surfaced from a stage/job variable.
$datacenterType = $null
if ($yaml -match '(?m)^\s*-\s*name\s*:\s*DatacenterType\s*\n\s*value\s*:\s*(\w+)') {
    $datacenterType = $Matches[1]
}

$ev2     = Get-Ev2-Task   -Text $yaml
if ($ev2) { $ev2 | Add-Member -NotePropertyName 'datacenterType' -NotePropertyValue $datacenterType -Force }
$sdsHint = Get-Sds-Hint   -Text $yaml
$selfRepo= Get-Self-Repo  -Text $yaml

return [pscustomobject]@{
    source             = $source
    name               = $header.name
    trigger            = $header.trigger
    parameters         = $params
    cloudConvention    = $cloudConvention
    cloudsDetected     = $cloudsDetected
    partitions         = $partModel.partitions
    stageHardcodedClouds = @($hard)
    stampParamShape    = $stampParamShape
    perCloudDefaults   = $perCloud
    flatDefaults       = $flatDefaults
    datacenterType     = $datacenterType
    ev2                = $ev2
    sdsHint            = $sdsHint
    selfRepo           = $selfRepo
    analyzedAt         = (Get-Date).ToUniversalTime().ToString('o')
}
