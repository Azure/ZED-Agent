<#
.SYNOPSIS
    Resolve the correct pipeline self-repository source branch for deployment pipeline
    triggers in Steps 5 (canary) and 10 (production/roll-forward).

.DESCRIPTION
    For Steps 5 and 10 the ADO pipeline YAML definition lives on a stable base branch
    (e.g. "develop"), NOT on the ZED working/release branch. Posting
    resources.repositories.self.refName = <workingBranch> for those pipelines causes ADO
    to return HTTP 400 "PipelineValidationException: No version was found for the pipeline"
    because the YAML does not exist on the release branch.

    This script reads yamlRepos.<repoName>.baseBranch from pipeline-catalog.json and
    returns the full ref string "refs/heads/<baseBranch>". It throws with an actionable
    message naming the missing key if yamlRepos or baseBranch is absent — silent fallback
    to the working branch is the root cause of the 400 failures and is explicitly rejected.

    Step 2 (officialBuild) must still use refs/heads/<currentBranch> because the build
    pipeline DOES exist on the release branch (it was just created). Do NOT call this
    script for Step 2.

.PARAMETER CatalogPath
    Full path to pipeline-catalog.json.

.PARAMETER RepoName
    Repository name key to look up under yamlRepos — typically CONFIG[ado.repository]
    from service-config.json (e.g. "Mgmt-RecoverySvcs-BackupDataPlane").

.OUTPUTS
    String: full ref e.g. "refs/heads/develop"

.EXAMPLE
    $sourceBranch = Get-YamlRepoSourceBranch `
        -CatalogPath '.github/skills/zed-agent/pipeline-catalog.json' `
        -RepoName 'Mgmt-RecoverySvcs-BackupDataPlane'
    # Returns: "refs/heads/develop"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CatalogPath,
    [Parameter(Mandatory)][string]$RepoName
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CatalogPath)) {
    throw "Get-YamlRepoSourceBranch: catalog file not found: $CatalogPath"
}

$catalog = Get-Content $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $catalog.yamlRepos) {
    throw "Get-YamlRepoSourceBranch: 'yamlRepos' block is missing from pipeline-catalog.json. " +
          "Add it to fix HTTP 400 on Steps 5/10: `"yamlRepos`": { `"$RepoName`": { `"baseBranch`": `"<branch>`" } }"
}

$repoEntry = $catalog.yamlRepos.PSObject.Properties[$RepoName]
if (-not $repoEntry) {
    throw "Get-YamlRepoSourceBranch: repo key '$RepoName' not found under yamlRepos in pipeline-catalog.json. " +
          "Add it: `"yamlRepos`": { `"$RepoName`": { `"baseBranch`": `"<branch>`" } }"
}

$baseBranch = $repoEntry.Value.baseBranch
if ([string]::IsNullOrWhiteSpace($baseBranch)) {
    throw "Get-YamlRepoSourceBranch: yamlRepos.$RepoName.baseBranch is empty or missing in pipeline-catalog.json. " +
          "Set it to the branch that holds the pipeline YAML (e.g. 'develop')."
}

return "refs/heads/$baseBranch"
