<#
.SYNOPSIS
    Static-analyses an Azure Pipelines YAML and returns a structured summary
    of cloud coverage, stamp/region defaults, EV2 task settings, and SDS hints.

.DESCRIPTION
    Tier 1 of the YAML+SDS inventory mechanism (Phase 11.4a).

    Reads YAML from disk (or stdin via -Content) and extracts everything
    setup-service needs to populate pipeline-catalog.json → yamlIntrospection:

      * Pipeline `parameters:` (reuses the same line-walker as Read-PipelineYaml).
      * Cloud convention — two known patterns:
          stageHardcoded     : stage-scope `value: <CloudName>` under a `cloud`
                               variable (DataMover-style: one pipeline = one cloud).
          perCloudScriptFlags: per-cloud `<Prefix>Script` boolean parameters
                               gated by `${{ if eq(parameters.<Prefix>Script, true) }}`
                               (Prot-style: one pipeline → many clouds).
      * Stamp/region defaults:
          flat               : parameters named `stamps`, `Excludestamps`, `Regions`,
                               `ExcludeRegions` (DataMover).
          perCloud           : parameters named `<Prefix>stamps`, `<Prefix>ExcludeStamps`,
                               `<Prefix>Regions`, `<Prefix>ExcludeRegions` (Prot).
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

.OUTPUTS
    PSCustomObject — see DESCRIPTION above for fields.
#>
[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Path')][string]$YamlPath,
    [Parameter(Mandatory=$true, ParameterSetName='Content')][string]$Content
)

$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw "YAML file not found: $YamlPath"
    }
    $yaml = Get-Content -LiteralPath $YamlPath -Raw
    $source = (Resolve-Path -LiteralPath $YamlPath).Path
} else {
    $yaml = $Content
    $source = '<inline>'
}

# Strip CRs for predictable regex behaviour.
$yaml = $yaml -replace "`r",''

# Known clouds in MAB-family pipelines (used for stage-hardcoded detection only).
$knownClouds = @('Public','Canary','Fairfax','Mooncake','USNat','USSec','Bleu','BVTD3','EXP')

function Get-Param-Block {
    param([string]$Text)
    $lines = $Text -split "`n"
    $inBlock = $false
    $blockIndent = -1
    $cur = $null
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if (-not $inBlock) {
            if ($line -match '^parameters\s*:\s*$') { $inBlock = $true }
            continue
        }
        if ($line.Trim().Length -eq 0) { continue }
        $indent = [regex]::Match($line,'^(\s*)').Groups[1].Length
        if ($blockIndent -lt 0 -and $line.Trim() -match '^-\s') { $blockIndent = $indent }
        if ($line -match '^\S' -and -not ($line.StartsWith(' '))) {
            if ($cur) { $out.Add([pscustomobject]$cur) | Out-Null; $cur = $null }
            $inBlock = $false
            continue
        }
        if ($line.Trim() -match '^-\s*name\s*:\s*(.+)$') {
            if ($cur) { $out.Add([pscustomobject]$cur) | Out-Null }
            $cur = [ordered]@{
                name        = $Matches[1].Trim().Trim("'`"")
                type        = $null
                default     = $null
                displayName = $null
                values      = @()
            }
        } elseif ($cur -and $line.Trim() -match '^(type|default|displayName)\s*:\s*(.*)$') {
            $val = $Matches[2].Trim()
            # Preserve raw string default (may itself contain quotes / @(...) syntax).
            if ($Matches[1] -eq 'default') { $cur.default = $val } else {
                $cur[$Matches[1]] = $val.Trim("'`"")
            }
        } elseif ($cur -and $line.Trim() -match '^-\s+(.+)$') {
            $cur.values += $Matches[1].Trim().Trim("'`"")
        }
    }
    if ($cur) { $out.Add([pscustomobject]$cur) | Out-Null }
    return $out.ToArray()
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

function Get-PerCloud-Stamp-Params {
    param([object[]]$Params, [string[]]$Prefixes)
    $out = [ordered]@{}
    foreach ($pre in $Prefixes) {
        $entry = [ordered]@{
            stamps         = $null
            excludeStamps  = $null
            regions        = $null
            excludeRegions = $null
        }
        foreach ($p in $Params) {
            $n = $p.name
            if     ($n -ieq "${pre}stamps")         { $entry.stamps = $p.default }
            elseif ($n -ieq "${pre}ExcludeStamps")  { $entry.excludeStamps = $p.default }
            elseif ($n -ieq "${pre}Excludestamps")  { $entry.excludeStamps = $p.default }
            elseif ($n -ieq "${pre}Regions")        { $entry.regions = $p.default }
            elseif ($n -ieq "${pre}ExcludeRegions") { $entry.excludeRegions = $p.default }
        }
        $out[$pre] = [pscustomobject]$entry
    }
    return [pscustomobject]$out
}

function Get-Flat-Stamp-Params {
    param([object[]]$Params)
    $entry = [ordered]@{
        stamps         = $null
        excludeStamps  = $null
        regions        = $null
        excludeRegions = $null
    }
    foreach ($p in $Params) {
        switch -Regex ($p.name) {
            '^stamps$'         { $entry.stamps = $p.default }
            '^Excludestamps$'  { $entry.excludeStamps = $p.default }
            '^ExcludeStamps$'  { $entry.excludeStamps = $p.default }
            '^Regions$'        { $entry.regions = $p.default }
            '^ExcludeRegions$' { $entry.excludeRegions = $p.default }
        }
    }
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
    # When the path resolves to a directory rather than the SDS file itself,
    # append the file name so downstream consumers get a complete repo-relative path.
    if ($repoPath -and -not ($repoPath.EndsWith($fileName, [System.StringComparison]::OrdinalIgnoreCase))) {
        $repoPath = "$repoPath/$fileName"
    }
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
    $entries = New-Object System.Collections.Generic.List[object]
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
$params  = Get-Param-Block     -Text $yaml
$hard    = Get-Stage-Hardcoded-Cloud -Text $yaml
$flags   = Get-PerCloud-ScriptFlags -Params $params

$cloudConvention = 'unknown'
$cloudsDetected  = @()
$stampParamShape = 'flat'
$perCloud        = $null
$flatDefaults    = $null

if ($flags.Count -gt 0) {
    $cloudConvention = 'perCloudScriptFlags'
    $cloudsDetected  = @($flags)
    $stampParamShape = 'perCloud'
    $perCloud        = Get-PerCloud-Stamp-Params -Params $params -Prefixes $flags
} elseif ($hard.Count -gt 0) {
    $cloudConvention = 'stageHardcoded'
    $cloudsDetected  = @($hard)
    $stampParamShape = 'flat'
    $flatDefaults    = Get-Flat-Stamp-Params -Params $params
} else {
    # No detectable convention — still try flat extraction so the owner has data
    # to confirm.
    $flatDefaults = Get-Flat-Stamp-Params -Params $params
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
    source           = $source
    name             = $header.name
    trigger          = $header.trigger
    parameters       = $params
    cloudConvention  = $cloudConvention
    cloudsDetected   = $cloudsDetected
    stampParamShape  = $stampParamShape
    perCloudDefaults = $perCloud
    flatDefaults     = $flatDefaults
    datacenterType   = $datacenterType
    ev2              = $ev2
    sdsHint          = $sdsHint
    selfRepo         = $selfRepo
    analyzedAt       = (Get-Date).ToUniversalTime().ToString('o')
}
