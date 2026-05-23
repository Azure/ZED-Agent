<#
.SYNOPSIS
    Fetches the YAML for an ADO pipeline from its source repo's base branch,
    recursively follows extends: template references (cross-repo allowed), and
    returns the merged 'parameters:' block with provenance.

.DESCRIPTION
    Used by setup-service Group 11 (Phase 11.1) to learn the declared parameter
    surface of a pipeline directly from source — including parameters added in
    extended templates the owner may not even know about.

    The script does NOT prompt for repo base branches. When it encounters a repo
    it cannot resolve a base branch for, it returns an entry in the output's
    .promptForRepos list and the caller (the wizard) must collect the answer
    via ask_user, persist to pipeline-catalog.json → yamlRepos.<repo>.baseBranch,
    and re-invoke. This keeps the script side-effect free.

    Auth: az login (Entra). Token is acquired on the fly with the ADO resource
    GUID — same pattern as Read-PriorRun.ps1.

.PARAMETER CatalogPath
    Path to pipeline-catalog.json. Used to read yamlRepos.<repo>.baseBranch
    overrides. Defaults to <repo-root>/.github/skills/zed-agent/pipeline-catalog.json.

.PARAMETER DefaultBaseBranch
    Fallback base branch if a repo has no entry under yamlRepos.<repo>.
    Defaults to service-config.json → ado.baseBranch when available, else 'main'.

.OUTPUTS
    PSCustomObject with:
      pipelineId       : int
      yamlRepo         : string (the root pipeline YAML repo name)
      yamlBranch       : string
      yamlPath         : string
      yamlSha          : string
      parameters       : ordered list of { name, type, default, values, _resolvedFrom: { repo, branch, path } }
      followedExtends  : list of every extends: chain edge resolved
      promptForRepos   : list of repo names the caller needs to collect a baseBranch for
                         (empty when all repos resolved). When non-empty, parameters
                         is partial — re-invoke after persisting the answers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][int]$PipelineId,
    [string]$CatalogPath,
    [string]$DefaultBaseBranch
)

$ErrorActionPreference = 'Stop'

# ── Resolve catalog path for yamlRepos lookup ──
if (-not $CatalogPath) {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($repoRoot) {
        $CatalogPath = Join-Path $repoRoot '.github\skills\zed-agent\pipeline-catalog.json'
    }
}
$catalog = $null
if ($CatalogPath -and (Test-Path $CatalogPath)) {
    $catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json
}

# ── Token ──
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) { throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com'." }
$headers = @{ Authorization = "Bearer $adoToken" }

function Get-RepoBaseBranch {
    param([string]$RepoName)
    if ($catalog -and $catalog.yamlRepos -and $catalog.yamlRepos.PSObject.Properties[$RepoName]) {
        return $catalog.yamlRepos.$RepoName.baseBranch
    }
    return $DefaultBaseBranch
}

function Get-RepoOrgProject {
    param([string]$RepoName)
    $org = $Organization
    $proj = $Project
    if ($catalog -and $catalog.yamlRepos -and $catalog.yamlRepos.PSObject.Properties[$RepoName]) {
        $e = $catalog.yamlRepos.$RepoName
        if ($e.organization) { $org = $e.organization }
        if ($e.project)      { $proj = $e.project }
    }
    return [PSCustomObject]@{ Organization = $org; Project = $proj }
}

function Get-YamlItem {
    param([string]$RepoName, [string]$BranchName, [string]$Path)
    $op = Get-RepoOrgProject -RepoName $RepoName
    # ADO Git items API — pull raw file content at the given branch.
    $uri = "https://dev.azure.com/$($op.Organization)/$($op.Project)/_apis/git/repositories/$RepoName/items" +
           "?path=$([uri]::EscapeDataString($Path))&versionDescriptor.version=$([uri]::EscapeDataString($BranchName))" +
           "&versionDescriptor.versionType=branch&includeContent=true&api-version=7.1"
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
    return [PSCustomObject]@{
        content = $resp.content
        sha     = $resp.objectId
    }
}

function ConvertFrom-YamlText {
    # Minimal YAML reader for our needs (parameters block + extends block).
    # Try powershell-yaml module if present; otherwise fall back to a tolerant
    # regex extractor that handles the common Azure Pipelines shape.
    param([string]$Yaml)
    if (Get-Module -ListAvailable -Name powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
        return ConvertFrom-Yaml $Yaml
    }
    # Tolerant fallback: just return the raw text — caller will regex it.
    return $Yaml
}

function Extract-Parameters {
    param([string]$Yaml)
    # Match a top-level 'parameters:' block of list-form param definitions.
    $out = New-Object System.Collections.Generic.List[object]
    $lines = $Yaml -split "`r?`n"
    $inBlock = $false
    $blockIndent = -1
    $current = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if (-not $inBlock) {
            if ($line -match '^(parameters|templateParameters)\s*:\s*$') {
                $inBlock = $true
            }
            continue
        }
        # Determine line indent
        $indentMatch = [regex]::Match($line, '^(\s*)')
        $indent = $indentMatch.Groups[1].Length
        if ($line.Trim().Length -eq 0) { continue }
        if ($blockIndent -lt 0 -and $line.Trim() -match '^-\s') { $blockIndent = $indent }
        if ($indent -lt $blockIndent -or ($line -match '^\S' -and $indent -eq 0)) {
            # Out of the parameters block
            if ($current) { $out.Add($current) | Out-Null }
            $current = $null
            $inBlock = $false
            continue
        }
        if ($line.Trim() -match '^-\s*name\s*:\s*(.+)$') {
            if ($current) { $out.Add($current) | Out-Null }
            $current = [ordered]@{
                name    = $Matches[1].Trim().Trim("'`"")
                type    = $null
                default = $null
                values  = @()
            }
        } elseif ($current -and $line.Trim() -match '^(type|default|displayName)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim("'`"")
            if ($key -eq 'type')    { $current.type    = $val }
            if ($key -eq 'default') { $current.default = $val }
        } elseif ($current -and $line.Trim() -match '^-\s+(.+)$') {
            # enum value
            $current.values += $Matches[1].Trim().Trim("'`"")
        }
    }
    if ($current) { $out.Add($current) | Out-Null }
    return $out
}

function Extract-Extends {
    param([string]$Yaml)
    # Returns @{ repo='<repoAlias>'; path='<path>' } or $null. Cross-repo extends:
    #   extends:
    #     template: path/to/template.yml@repoAlias
    # The repoAlias is then declared in a 'resources.repositories' block.
    if ($Yaml -match 'extends\s*:\s*\r?\n\s+template\s*:\s*([^\r\n]+)') {
        $ref = $Matches[1].Trim().Trim("'`"")
        if ($ref -match '^(.+?)@(.+)$') {
            return [PSCustomObject]@{ path = $Matches[1]; repoAlias = $Matches[2] }
        }
        return [PSCustomObject]@{ path = $ref; repoAlias = $null }
    }
    return $null
}

function Resolve-RepoAlias {
    param([string]$Yaml, [string]$Alias)
    # resources:
    #   repositories:
    #     - repository: <alias>
    #       name: <Project>/<RepoName>  OR  <RepoName>
    #       ref: refs/heads/<branch>    (optional)
    $pattern = '(?ms)resources\s*:\s*\r?\n\s+repositories\s*:\s*\r?\n(.+?)(?:\r?\n[A-Za-z]|\z)'
    if ($Yaml -notmatch $pattern) { return $null }
    $block = $Matches[1]
    $blockLines = $block -split "`r?`n"
    $entries = @()
    $cur = $null
    foreach ($l in $blockLines) {
        if ($l -match '^\s*-\s*repository\s*:\s*(.+)$') {
            if ($cur) { $entries += $cur }
            $cur = @{ repository = $Matches[1].Trim().Trim("'`"") }
        } elseif ($cur -and $l -match '^\s+(name|ref|type)\s*:\s*(.+)$') {
            $cur[$Matches[1]] = $Matches[2].Trim().Trim("'`"")
        }
    }
    if ($cur) { $entries += $cur }
    $match = $entries | Where-Object { $_.repository -eq $Alias } | Select-Object -First 1
    if (-not $match) { return $null }
    $name = $match.name
    $repoName = $name
    if ($name -match '/') { $repoName = ($name -split '/')[-1] }
    $branch = $null
    if ($match.ref -match '^refs/heads/(.+)$') { $branch = $Matches[1] }
    return [PSCustomObject]@{ repoName = $repoName; branch = $branch }
}

# ── 1. Get pipeline definition to discover root YAML location ──
$pipelineUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/${PipelineId}?api-version=7.1"
$pipeline = Invoke-RestMethod -Uri $pipelineUri -Headers $headers -ErrorAction Stop
$rootRepoName = $pipeline.configuration.repository.name
if (-not $rootRepoName) { $rootRepoName = $pipeline.configuration.repository.fullName }
$rootPath = $pipeline.configuration.path

$promptFor = @()
$followed  = @()
$allParams = New-Object System.Collections.Generic.List[object]

# ── 2. Walk the YAML chain ──
$queue = New-Object System.Collections.Generic.Queue[object]
$rootBranch = Get-RepoBaseBranch -RepoName $rootRepoName
if (-not $rootBranch) {
    $promptFor += $rootRepoName
    return [PSCustomObject]@{
        pipelineId      = $PipelineId
        yamlRepo        = $rootRepoName
        yamlBranch      = $null
        yamlPath        = $rootPath
        yamlSha         = $null
        parameters      = @()
        followedExtends = @()
        promptForRepos  = $promptFor
    }
}
$queue.Enqueue([PSCustomObject]@{ repoName = $rootRepoName; branch = $rootBranch; path = $rootPath })

$visited = @{}
$rootSha = $null
while ($queue.Count -gt 0) {
    $node = $queue.Dequeue()
    $key = "$($node.repoName)|$($node.branch)|$($node.path)"
    if ($visited.ContainsKey($key)) { continue }
    $visited[$key] = $true
    try {
        $item = Get-YamlItem -RepoName $node.repoName -BranchName $node.branch -Path $node.path
    } catch {
        Write-Warning "Could not fetch $($node.repoName)@$($node.branch):$($node.path) — $($_.Exception.Message)"
        continue
    }
    if (-not $rootSha) { $rootSha = $item.sha }
    $params = Extract-Parameters -Yaml $item.content
    foreach ($p in $params) {
        $p._resolvedFrom = [PSCustomObject]@{ repo = $node.repoName; branch = $node.branch; path = $node.path }
        $allParams.Add([PSCustomObject]$p) | Out-Null
    }
    $ext = Extract-Extends -Yaml $item.content
    if ($ext) {
        $nextRepo = $node.repoName
        $nextBranch = $node.branch
        if ($ext.repoAlias) {
            $resolved = Resolve-RepoAlias -Yaml $item.content -Alias $ext.repoAlias
            if ($resolved) {
                $nextRepo = $resolved.repoName
                $bb = Get-RepoBaseBranch -RepoName $nextRepo
                if (-not $bb) {
                    if ($promptFor -notcontains $nextRepo) { $promptFor += $nextRepo }
                    continue
                }
                $nextBranch = $resolved.branch ? $resolved.branch : $bb
            }
        }
        $followed += [PSCustomObject]@{ from = $key; toRepo = $nextRepo; toBranch = $nextBranch; toPath = $ext.path }
        $queue.Enqueue([PSCustomObject]@{ repoName = $nextRepo; branch = $nextBranch; path = $ext.path })
    }
}

# ── 3. Dedupe parameters by name (last write wins — extended templates can override defaults) ──
$byName = [ordered]@{}
foreach ($p in $allParams) { $byName[$p.name] = $p }
$mergedParams = @($byName.Values)

return [PSCustomObject]@{
    pipelineId      = $PipelineId
    yamlRepo        = $rootRepoName
    yamlBranch      = $rootBranch
    yamlPath        = $rootPath
    yamlSha         = $rootSha
    parameters      = $mergedParams
    followedExtends = $followed
    promptForRepos  = $promptFor
}
