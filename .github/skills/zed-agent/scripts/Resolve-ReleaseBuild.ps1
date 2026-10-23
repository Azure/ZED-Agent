<#
.SYNOPSIS
    Release builds for services that DEPLOY THE BASE BRANCH itself instead of cutting a release
    branch (service-config.json → ado.releaseMode = "deploy-base", e.g. BCM deploys master).

.DESCRIPTION
    Actions
      PreviousRelease  Finds the previous release from the production pipelines' own history: the
                       newest production run (catalog production.*) that is a real rollout
                       (ValidateOnlyRollOut not true, not canceled/failed) and the build it consumed
                       through its pinned build resource (catalog production.<key>.buildResource)
                       → previousBuildId / previousBuildNumber / previousCommit (the build's source
                       commit). Also returns up to 6 Candidates (distinct builds, newest first) so
                       the owner can pick another one.
      DeployCommit     Newest commit of origin/<DeployBranch> on the first-parent chain, skipping the
                       build-version bump commits (subject contains ***NO_CI***), and the official
                       build of exactly that commit if CI already queued one (succeeded / running).
      QueueBuild       Queues the official build (catalog officialBuild) on refs/heads/<DeployBranch>
                       pinned to -Commit (resources.repositories.self.version). Use only when
                       DeployCommit found no build.
      ResolveBuild     Build link (…/_build/results?buildId=N) or id → { buildId, buildNumber, branch,
                       commit, status, result } (validates it is an official build).
      PinResources     -BuildId → the version of that build in the artifact feed
                       (catalog artifactFeed) and, for -PipelineKey 'canary:<k>' / 'production:<k>' /
                       -Alias <name>, the run-request fragment
                       resources.builds.<alias>.version = <versionId>, so the deployment consumes
                       exactly that build instead of the newest build of ArtifactsBranch.

.OUTPUTS
    PSCustomObject per action (always includes Success / Error).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('PreviousRelease', 'DeployCommit', 'QueueBuild', 'ResolveBuild', 'PinResources')][string]$Action,
    [string]$DeployBranch,
    [string]$Commit,
    [string]$Build,
    [long]$BuildId,
    [string]$PipelineKey,
    [string]$Alias,
    [string]$RepoPath = (Get-Location).Path,
    [string]$Remote = 'origin',
    [string]$ServiceConfigPath,
    [string]$PipelineCatalogPath,
    [string]$AccessToken,
    [int]$RunsToScan = 30
)

$ErrorActionPreference = 'Stop'

$out = [ordered]@{ Success = $false; Action = $Action; Error = $null }

function Get-AdoToken {
    if ($script:AccessToken) { return $script:AccessToken }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $t = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null } finally { $ErrorActionPreference = $prev }
    if (-not $t) { throw "Failed to acquire ADO token. Run 'az login --tenant microsoft.com'." }
    $script:AccessToken = $t
    return $t
}

function Invoke-Ado([string]$Method, [string]$Uri, $Body) {
    $h = @{ Authorization = "Bearer $(Get-AdoToken)" }
    $p = @{ Uri = $Uri; Method = $Method; Headers = $h; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = (ConvertTo-Json -InputObject $Body -Depth 10); $p.ContentType = 'application/json' }
    return Invoke-RestMethod @p
}

function Invoke-Git([string[]]$GitArgs, [switch]$AllowFail) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & git -C $RepoPath @GitArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $lines = @($o | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $AllowFail) { throw "git $($GitArgs -join ' ') failed: $($lines -join ' ')" }
    return [pscustomobject]@{ Code = $code; Out = $lines }
}

function Get-BuildIdFromVersionName([string]$Name) {
    if ($Name -match '_(\d+)(\s|$)') { return [long]$Matches[1] }
    return $null
}

function Test-ValidateOnly($Run) {
    $tp = $Run.templateParameters
    if (-not $tp) { return $false }
    foreach ($p in $tp.PSObject.Properties) {
        if ($p.Name -match '^(ValidateOnlyRollOut|ValidateOnly)$' -and "$($p.Value)" -match '^(?i)true$') { return $true }
    }
    return $false
}

function Get-Build([long]$Id) { return Invoke-Ado GET "$($script:OrgBase)/build/builds/$($Id)?api-version=7.1" $null }

function Get-CatalogEntry([string]$Key) {
    if ($Key -notmatch '^(canary|production):(.+)$') { throw "PipelineKey '$Key' must look like 'canary:<key>' or 'production:<key>'." }
    $scope = $Matches[1]; $k = $Matches[2]
    $e = $script:Catalog.$scope.PSObject.Properties[$k]
    if (-not $e) { throw "pipeline-catalog.json has no $scope.$k." }
    return $e.Value
}

try {
    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    if (-not $PipelineCatalogPath) { $PipelineCatalogPath = Join-Path $PSScriptRoot '..\pipeline-catalog.json' }
    $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Catalog = Get-Content -LiteralPath $PipelineCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:AccessToken = $AccessToken
    $org = $svc.ado.organization; $proj = $svc.ado.project
    $script:OrgBase = "https://dev.azure.com/$org/$proj/_apis"
    if (-not $DeployBranch) { $DeployBranch = [string]$svc.ado.baseBranch }
    $DeployBranch = $DeployBranch -replace '^refs/heads/', ''
    $officialId = [int]$script:Catalog.officialBuild.id

    switch ($Action) {
        'PreviousRelease' {
            $found = New-Object System.Collections.Generic.List[object]
            foreach ($p in $script:Catalog.production.PSObject.Properties) {
                $entry = $p.Value
                $alias = [string]$entry.buildResource
                if (-not $alias) { throw "pipeline-catalog.json → production.$($p.Name).buildResource is required to find the previous release." }
                $list = Invoke-Ado GET "$($script:OrgBase)/build/builds?definitions=$($entry.id)&`$top=$RunsToScan&queryOrder=queueTimeDescending&api-version=7.1" $null
                foreach ($b in @($list.value)) {
                    if ($b.result -in @('canceled', 'failed')) { continue }
                    $run = Invoke-Ado GET "$($script:OrgBase)/pipelines/$($entry.id)/runs/$($b.id)?api-version=7.1" $null
                    if (Test-ValidateOnly $run) { continue }
                    $res = $run.resources.builds.$alias
                    if (-not $res) { continue }
                    $bid = Get-BuildIdFromVersionName ([string]$res.versionName)
                    if (-not $bid) { continue }
                    $found.Add([pscustomobject]@{ prodRunId = $b.id; prodPipeline = $p.Name; queued = ([datetime]$b.queueTime).ToUniversalTime().ToString('o'); prodResult = $(if ($b.result) { [string]$b.result } else { [string]$b.status }); buildId = $bid; versionName = [string]$res.versionName })
                }
            }
            $ordered = @($found | Sort-Object { [datetime]$_.queued } -Descending)
            $seen = @{}; $cands = New-Object System.Collections.Generic.List[object]
            foreach ($f in $ordered) {
                if ($seen.ContainsKey($f.buildId) -or $cands.Count -ge 6) { continue }
                $seen[$f.buildId] = $true
                $sb = Get-Build $f.buildId
                $sbBranch = ([string]$sb.sourceBranch) -replace '^refs/heads/', ''
                $cands.Add([pscustomobject]@{
                        buildId = $f.buildId; buildNumber = [string]$sb.buildNumber; commit = [string]$sb.sourceVersion
                        branch = $sbBranch
                        buildUrl = "https://dev.azure.com/$org/$proj/_build/results?buildId=$($f.buildId)"
                        deployedAt = $f.queued; prodRunId = $f.prodRunId; prodPipeline = $f.prodPipeline; prodResult = $f.prodResult
                    })
            }
            if ($cands.Count -eq 0) { throw "No real production rollout found in the last $RunsToScan runs of the production pipelines." }
            $top = $cands[0]
            $out.PreviousBuildId = $top.buildId; $out.PreviousBuildNumber = $top.buildNumber; $out.PreviousCommit = $top.commit
            $out.PreviousBranch = $top.branch; $out.PreviousBuildUrl = $top.buildUrl; $out.DeployedAt = $top.deployedAt; $out.ProdRunId = $top.prodRunId
            $out.Candidates = $cands.ToArray()
        }
        'DeployCommit' {
            $null = Invoke-Git @('fetch', '--quiet', $Remote, "+refs/heads/${DeployBranch}:refs/remotes/$Remote/$DeployBranch")
            $log = Invoke-Git @('log', '--first-parent', '--format=%H%x1f%s%x1f%cI', '-50', "$Remote/$DeployBranch")
            $pick = $null
            foreach ($line in $log.Out) {
                $f = $line -split [char]0x1f
                if ($f[1] -match '\*\*\*NO_CI\*\*\*') { continue }
                $pick = [pscustomobject]@{ sha = $f[0]; subject = $f[1]; date = $f[2] }; break
            }
            if (-not $pick) { throw "No deployable commit (all recent commits on $DeployBranch are ***NO_CI***)." }
            $out.Commit = $pick.sha; $out.Subject = $pick.subject; $out.CommitDate = $pick.date; $out.DeployBranch = $DeployBranch
            $builds = Invoke-Ado GET "$($script:OrgBase)/build/builds?definitions=$officialId&branchName=refs/heads/$DeployBranch&`$top=25&queryOrder=queueTimeDescending&api-version=7.1" $null
            $match = @($builds.value | Where-Object { $_.sourceVersion -eq $pick.sha -and $_.result -notin @('canceled', 'failed') })
            $best = @($match | Where-Object { $_.result -in @('succeeded', 'partiallySucceeded') }) + @($match | Where-Object { $_.status -ne 'completed' }) | Select-Object -First 1
            if ($best) {
                $out.BuildId = [long]$best.id; $out.BuildNumber = [string]$best.buildNumber
                $out.BuildStatus = [string]$best.status; $out.BuildResult = [string]$best.result
                $out.BuildUrl = "https://dev.azure.com/$org/$proj/_build/results?buildId=$($best.id)"
            } else { $out.BuildId = $null }
        }
        'QueueBuild' {
            if ($Commit -notmatch '^[0-9a-f]{40}$') { throw "-Commit must be a full 40-character sha." }
            $tp = [ordered]@{}
            if ($script:Catalog.officialBuild.templateParameters) { foreach ($p in $script:Catalog.officialBuild.templateParameters.PSObject.Properties) { $tp[$p.Name] = [string]$p.Value } }
            $body = [pscustomobject]@{
                resources = [pscustomobject]@{ repositories = [pscustomobject]@{ self = [pscustomobject]@{ refName = "refs/heads/$DeployBranch"; version = $Commit } } }
                templateParameters = [pscustomobject]$tp
            }
            $r = Invoke-Ado POST "$($script:OrgBase)/pipelines/$officialId/runs?api-version=7.1" $body
            $out.BuildId = [long]$r.id; $out.BuildNumber = [string]$r.name; $out.Commit = $Commit
            $out.BuildUrl = "https://dev.azure.com/$org/$proj/_build/results?buildId=$($r.id)"
        }
        'ResolveBuild' {
            $ref = if ($Build) { $Build.Trim() } else { "$BuildId" }
            $id = $null
            if ($ref -match '(?i)[?&]buildId=(\d+)') { $id = [long]$Matches[1] } elseif ($ref -match '^\d+$') { $id = [long]$ref }
            if (-not $id) { throw "'$ref' is not a build link (…/_build/results?buildId=<id>) or a build id." }
            try { $b = Get-Build $id } catch { throw "Build $id was not found in $org/$proj." }
            if ([int]$b.definition.id -ne $officialId) { throw "Build $id is from pipeline '$($b.definition.name)' ($($b.definition.id)), not the official build ($officialId)." }
            $out.BuildId = $id; $out.BuildNumber = [string]$b.buildNumber; $out.Commit = [string]$b.sourceVersion
            $out.Branch = ([string]$b.sourceBranch) -replace '^refs/heads/', ''
            $out.BuildStatus = [string]$b.status; $out.BuildResult = [string]$b.result
            $out.BuildUrl = "https://dev.azure.com/$org/$proj/_build/results?buildId=$id"
        }
        'PinResources' {
            if (-not $BuildId) { throw "-BuildId is required." }
            $feedCfg = $script:Catalog.artifactFeed
            if (-not $feedCfg -or -not $feedCfg.feedBranchPrefix) { throw "pipeline-catalog.json → artifactFeed is required to pin builds." }
            if (-not $Alias) { if ($PipelineKey) { $Alias = [string](Get-CatalogEntry $PipelineKey).buildResource } }
            if (-not $Alias) { throw "No build resource alias: pass -Alias, or set buildResource on catalog entry '$PipelineKey'." }
            $b = Get-Build $BuildId
            if ($b.status -ne 'completed' -or $b.result -notin @('succeeded', 'partiallySucceeded')) {
                throw "Build $BuildId ($($b.buildNumber)) is '$($b.status)'/'$($b.result)' — only a successfully completed build can be deployed."
            }
            $branch = ([string]$b.sourceBranch) -replace '^refs/heads/', ''
            $feed = [string]$feedCfg.feedBranchPrefix + ($branch -replace '[/.-]', '_')
            $src = [pscustomobject]@{
                alias = $Alias; type = $(if ($feedCfg.type) { [string]$feedCfg.type } else { 'CloudVaultArtifacts-v3' })
                definitionReference = [pscustomobject]@{
                    connection = [pscustomobject]@{ id = [string]$feedCfg.connectionId; name = [string]$feedCfg.connectionName }
                    definition = [pscustomobject]@{ id = [string]$feedCfg.sourceId; name = [string]$feedCfg.sourceId }
                    branch     = [pscustomobject]@{ id = $feed; name = $feed }
                }
            }
            $resp = Invoke-Ado POST "https://vsrm.dev.azure.com/$org/$proj/_apis/Release/artifacts/versions?api-version=7.1" @($src)
            $av = @($resp.artifactVersions)[0]
            if ($av.errorMessage) { throw "Artifact feed '$feed': $($av.errorMessage)" }
            $hit = @($av.versions | Where-Object { (Get-BuildIdFromVersionName ([string]$_.name)) -eq $BuildId }) | Select-Object -First 1
            if (-not $hit) { throw "Build $BuildId ($($b.buildNumber)) is not (yet) in artifact feed '$feed' ($(@($av.versions).Count) newest versions listed)." }
            $out.BuildId = $BuildId; $out.BuildNumber = [string]$b.buildNumber; $out.Branch = $branch; $out.Commit = [string]$b.sourceVersion
            $out.Feed = $feed; $out.Alias = $Alias; $out.VersionId = [string]$hit.id; $out.VersionName = [string]$hit.name
            $out.Resources = [pscustomobject]@{ builds = [pscustomobject]@{ $Alias = [pscustomobject]@{ version = [string]$hit.id } } }
        }
    }
    $out.Success = $true
} catch {
    $out.Error = $_.Exception.Message
    throw
}

return [pscustomobject]$out
