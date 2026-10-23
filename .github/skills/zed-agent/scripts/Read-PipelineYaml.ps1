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

.PARAMETER UsePreviewApi
    Skip the extends: walk and ask ADO to resolve the pipeline for us via
    POST /_apis/pipelines/{id}/preview, which returns `finalYaml` — the fully
    expanded definition including every extended template. Used automatically
    as a fallback when the extends: walk yields no parameters.

.PARAMETER PreviewRef
    Fully-qualified ref for the preview call (e.g. refs/heads/develop).
    Defaults to refs/heads/<resolved base branch>.

.PARAMETER LocalRepoRoot
    Optional absolute path to a local clone of the root pipeline repo. When set,
    Get-YamlItem tries the local file first (Join-Path $LocalRepoRoot $Path) and
    only falls back to the ADO Git Items API if the file is not on disk. Useful
    when the wizard runs on a machine that already has the repo cloned — bypasses
    404s caused by ADO repo-id/name mismatches.

.PARAMETER AllowEmptyParameters
    Escape hatch for pipelines that genuinely declare no parameters. Without
    it, an empty parameter surface is a hard error — writing `null` and
    continuing is the silent no-op this guards against.

.OUTPUTS
    PSCustomObject with:
      pipelineId       : int
      yamlRepo         : string (the root pipeline YAML repo name)
      yamlBranch       : string
      yamlPath         : string
      yamlSha          : string
      yamlContent      : string (the text actually analysed)
      source           : string (real provenance on THIS machine / this endpoint)
      resolvedVia      : 'gitItems' | 'previewApi'
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
    [string]$DefaultBaseBranch,
    [string]$LocalRepoRoot,
    [switch]$UsePreviewApi,
    [string]$PreviewRef,
    [switch]$AllowEmptyParameters
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\YamlParamModel.ps1')

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
    # Local-clone fast path: when the caller passed -LocalRepoRoot and the file is
    # on disk, return its content without an ADO round-trip. The sha is synthesized
    # from the file hash and prefixed 'local:' so downstream provenance records stay
    # stable while remaining distinguishable from a real ADO objectId.
    if ($LocalRepoRoot -and (Test-Path -LiteralPath $LocalRepoRoot)) {
        $relPath   = $Path.TrimStart('/', '\')
        $localFile = Join-Path $LocalRepoRoot $relPath
        if (Test-Path -LiteralPath $localFile) {
            $content = Get-Content -LiteralPath $localFile -Raw
            $sha     = (Get-FileHash -LiteralPath $localFile -Algorithm SHA1).Hash.ToLowerInvariant()
            return [PSCustomObject]@{ content = $content; sha = "local:$sha" }
        }
    }
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
    # Delegates to the shared, indentation-tolerant walker (lib/YamlParamModel.ps1).
    # Azure Pipelines allows the `parameters:` sequence at column 0, which an
    # indentation-only walker silently reads as zero parameters.
    param([string]$Yaml)
    return @(Get-YamlParameterBlock -Yaml $Yaml)
}

function Get-PreviewYaml {
    # Ask ADO to fully resolve the pipeline (all `extends:` templates expanded)
    # and hand back `finalYaml`.
    param([int]$Id, [string]$Ref)
    $uri  = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/$Id/preview?api-version=7.1-preview.1"
    $body = @{ previewRun = $true } 
    if ($Ref) { $body.resources = @{ repositories = @{ self = @{ refName = $Ref } } } }
    $json = $body | ConvertTo-Json -Depth 6
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $json -ErrorAction Stop
    return [PSCustomObject]@{ content = $resp.finalYaml; source = $uri + " (ref=$Ref)" }
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
$resolvedVia = 'gitItems'
$yamlContent = $null
$sourceLabel = $null

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
        yamlContent     = $null
        source          = $null
        resolvedVia     = $null
        parameters      = @()
        followedExtends = @()
        promptForRepos  = $promptFor
    }
}
if (-not $PreviewRef) { $PreviewRef = "refs/heads/$rootBranch" }
$queue.Enqueue([PSCustomObject]@{ repoName = $rootRepoName; branch = $rootBranch; path = $rootPath })

$visited = @{}
$rootSha = $null
if (-not $UsePreviewApi) {
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
    if (-not $yamlContent) {
        $yamlContent = $item.content
        $sourceLabel = "$($node.repoName)@$($node.branch):$($node.path)"
    }
    $params = Extract-Parameters -Yaml $item.content
    foreach ($p in $params) {
        $p | Add-Member -NotePropertyName '_resolvedFrom' -NotePropertyValue ([PSCustomObject]@{
            repo = $node.repoName; branch = $node.branch; path = $node.path }) -Force
        $allParams.Add($p) | Out-Null
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
}

# ── 3. Fallback: ask ADO to fully resolve the pipeline for us ──
# The extends: walk cannot follow templates behind repo resources we have no
# baseBranch for, and cannot resolve template expressions. When it comes back
# empty (or the caller asked for it up front), use the preview endpoint, which
# returns the same YAML the service itself would compile.
if ($UsePreviewApi -or $allParams.Count -eq 0) {
    try {
        $preview = Get-PreviewYaml -Id $PipelineId -Ref $PreviewRef
        if ($preview.content) {
            $previewParams = @(Extract-Parameters -Yaml $preview.content)
            if ($previewParams.Count -gt 0 -or $UsePreviewApi) {
                $allParams.Clear()
                foreach ($p in $previewParams) {
                    $p | Add-Member -NotePropertyName '_resolvedFrom' -NotePropertyValue ([PSCustomObject]@{
                        repo = $rootRepoName; branch = $rootBranch; path = $rootPath }) -Force
                    $allParams.Add($p) | Out-Null
                }
                $yamlContent = $preview.content
                $sourceLabel = $preview.source
                $resolvedVia = 'previewApi'
                $promptFor   = @()
            }
        }
    } catch {
        Write-Warning "Preview API resolution failed for pipeline ${PipelineId}: $($_.Exception.Message)"
    }
}

# ── 4. Dedupe parameters by name (last write wins — extended templates can override defaults) ──
$byName = [ordered]@{}
foreach ($p in $allParams) { $byName[$p.name] = $p }
$mergedParams = @($byName.Values)

if ($mergedParams.Count -eq 0 -and -not $AllowEmptyParameters -and $promptFor.Count -eq 0) {
    throw ("Read-PipelineYaml: pipeline $PipelineId ($Organization/$Project) resolved to ZERO parameters. " +
           "Writing an empty parameter surface into the catalog is a silent no-op that later produces " +
           "wrong templateParameters. Verify the pipeline really declares no 'parameters:' block " +
           "(re-run with -AllowEmptyParameters to accept that), or investigate the preview endpoint " +
           "POST /_apis/pipelines/$PipelineId/preview?api-version=7.1-preview.1 with ref '$PreviewRef'.")
}

return [PSCustomObject]@{
    pipelineId      = $PipelineId
    yamlRepo        = $rootRepoName
    yamlBranch      = $rootBranch
    yamlPath        = $rootPath
    yamlSha         = $rootSha
    yamlContent     = $yamlContent
    source          = $sourceLabel
    resolvedVia     = $resolvedVia
    parameters      = $mergedParams
    followedExtends = $followed
    promptForRepos  = $promptFor
}
