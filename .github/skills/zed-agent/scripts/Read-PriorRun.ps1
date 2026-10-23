<#
.SYNOPSIS
    Returns a normalized record per ADO pipeline run — templateParameters,
    sourceBranch, definitionId, result — either for explicit run ids the
    release owner supplied, or for the most recent runs of a pipeline.

.DESCRIPTION
    Used by setup-service Phase 4.3 to learn the real-world parameter shape of
    a pipeline from runs a human actually authored, rather than asking the
    release owner to recite 30 parameters from memory.

    Two modes:

      -RunIds <id,...>     The owner pastes run/build URLs from a real release.
                           ZED resolves each id to its pipeline itself via the
                           Build API, so the owner never has to say which run
                           belongs to which pipeline. -PipelineId is optional
                           here and, when given, is enforced: a run belonging
                           to a different definition is a hard error, never a
                           silent mis-attribution.

      -PipelineId <id>     Fallback discovery mode: list the pipeline's recent
                           runs so the owner can pick. Defaults to -ResultFilter
                           'any' because release runs are frequently cancelled
                           after the rollout is verified, and filtering to
                           'succeeded' hides exactly the runs worth learning
                           from.

    Runs ZED authored itself are hard-excluded in both modes (see
    Get-SelfAuthoredRuns.ps1). Identity filtering cannot do this: ZED runs
    under the owner's delegated token, so `requestedFor` and `reason` are
    identical for human-queued and ZED-queued runs. Only the ledger of run ids
    ZED recorded at trigger time can tell them apart.

    Auth: az login (Entra). Token is acquired on the fly with the ADO resource
    GUID (499b84ac-1321-427f-aa17-267ca6975798) — same pattern as
    Get-RegionMapping.ps1 and Get-Ev2RolloutStatus.ps1.

.PARAMETER RunIds
    Explicit run (build) ids to read. ZED resolves each one's owning pipeline.

.PARAMETER PipelineId
    Mandatory in discovery mode. Optional in -RunIds mode, where it acts as an
    assertion that every supplied run belongs to that pipeline.

.PARAMETER ResultFilter
    Discovery mode only. 'any' (default) returns runs regardless of outcome.

.PARAMETER ReleaseGroup
    Opaque tag identifying the release these runs belong to. Consumers use it
    to count how many *independent* releases agree on a value. Defaults to the
    run's own source branch.

.PARAMETER RepoRoot
    Deployment repo root used to locate the self-authored run ledger.
    Defaults to the current directory.

.PARAMETER SelfAuthoredRunIds
    Explicit exclusion list. Overrides ledger discovery when supplied.

.PARAMETER IncludeSelfAuthored
    Escape hatch — disables the exclusion. Diagnostics only; never use this to
    build a parameter model.

.OUTPUTS
    Array of PSCustomObjects (most recent first):
      runId, definitionId, runUrl, finishedAt, sourceBranch, releaseGroup,
      result, state, templateParameters

    Returns @() when nothing matches.
#>
[CmdletBinding(DefaultParameterSetName = 'ByPipeline')]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true, ParameterSetName = 'ByRunIds')][int[]]$RunIds,
    [Parameter(Mandatory = $true, ParameterSetName = 'ByPipeline')]
    [Parameter(Mandatory = $false, ParameterSetName = 'ByRunIds')][int]$PipelineId,
    [Parameter(ParameterSetName = 'ByPipeline')][int]$Top = 3,
    [Parameter(ParameterSetName = 'ByPipeline')]
    [ValidateSet('succeeded','failed','canceled','any')]
    [string]$ResultFilter = 'any',
    [string]$ReleaseGroup,
    [string]$RepoRoot = (Get-Location).Path,
    [int[]]$SelfAuthoredRunIds,
    [switch]$IncludeSelfAuthored
)

$ErrorActionPreference = 'Stop'

# -- Acquire ADO-scoped token via az login --
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) {
    throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com' and retry."
}
$headers = @{ Authorization = "Bearer $adoToken" }
function Get-AdoBaseCandidates {
    param([string]$Org, [string]$Proj)
    # Known org quirk: msazure/One can 404 on dev.azure.com for some build APIs
    # while visualstudio.com succeeds with the same token, so try that host first
    # for this org/project pair and keep dev.azure.com as the fallback.
    if ($Org -ieq 'msazure' -and $Proj -ieq 'One') {
        return @("https://msazure.visualstudio.com/$Proj", "https://dev.azure.com/$Org/$Proj")
    }
    return @("https://dev.azure.com/$Org/$Proj", "https://$Org.visualstudio.com/$Proj")
}

$adoBases    = Get-AdoBaseCandidates -Org $Organization -Proj $Project
$browserBase = $adoBases[0]

function Invoke-AdoJsonGet {
    # Walks the candidate hosts in order and returns the first successful JSON
    # body. Only throws once every host has failed, reporting the last error.
    param([string]$RelativeApiPath)
    $lastErr = $null
    foreach ($base in $adoBases) {
        $uri = "$base/_apis/$RelativeApiPath"
        try {
            return (Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop)
        } catch {
            $lastErr = $_.Exception.Message
            continue
        }
    }
    throw "ADO GET failed for '$RelativeApiPath' on all hosts ($($adoBases -join ', ')): $lastErr"
}

# -- Self-authored exclusion set --
$excluded = @()
if (-not $IncludeSelfAuthored) {
    if ($PSBoundParameters.ContainsKey('SelfAuthoredRunIds')) {
        $excluded = @($SelfAuthoredRunIds)
    } else {
        $ledgerScript = Join-Path $PSScriptRoot 'Get-SelfAuthoredRuns.ps1'
        if (Test-Path -LiteralPath $ledgerScript) {
            try { $excluded = @(& $ledgerScript -RepoRoot $RepoRoot -IdsOnly) }
            catch { Write-Warning "Self-authored ledger unavailable - proceeding without exclusion. $($_.Exception.Message)" }
        }
    }
}
$excludedSet = @{}
foreach ($e in $excluded) { $excludedSet[[string]$e] = $true }

function Resolve-DefinitionId {
    # The Pipelines run endpoint requires the pipeline id up front, so an
    # owner-pasted build id has to be resolved through the Build API first.
    param([int]$BuildId)
    $build = Invoke-AdoJsonGet -RelativeApiPath "build/builds/${BuildId}?api-version=7.1"
    return [int]$build.definition.id
}

function Get-RunRecord {
    param([int]$DefinitionId, [int]$RunId)
    $detail = Invoke-AdoJsonGet -RelativeApiPath "pipelines/$DefinitionId/runs/${RunId}?api-version=7.1-preview.1"
    $tp = [ordered]@{}
    if ($detail.templateParameters) {
        foreach ($p in $detail.templateParameters.PSObject.Properties) { $tp[$p.Name] = $p.Value }
    }
    $branch = $detail.resources.repositories.self.refName
    $group  = if ($ReleaseGroup) { $ReleaseGroup } elseif ($branch) { $branch } else { "run:$RunId" }
    return [PSCustomObject]@{
        runId              = $RunId
        definitionId       = $DefinitionId
        runUrl             = "$browserBase/_build/results?buildId=$RunId"
        finishedAt         = $detail.finishedDate
        sourceBranch       = $branch
        releaseGroup       = $group
        result             = $detail.result
        state              = $detail.state
        templateParameters = $tp
    }
}

$out = New-Object System.Collections.Generic.List[object]

if ($PSCmdlet.ParameterSetName -eq 'ByRunIds') {
    $skipped = @()
    foreach ($rid in @($RunIds)) {
        if ($excludedSet.ContainsKey([string]$rid)) {
            $skipped += $rid
            Write-Warning "Run $rid was authored by ZED itself (self-authored ledger) and is excluded - learning from it would make ZED's own mistakes permanent."
            continue
        }
        try { $defId = Resolve-DefinitionId -BuildId $rid }
        catch { throw "Could not resolve run $rid to a pipeline definition in $Organization/${Project}: $($_.Exception.Message)" }

        if ($PSBoundParameters.ContainsKey('PipelineId') -and $PipelineId -gt 0 -and $defId -ne $PipelineId) {
            throw ("Run $rid belongs to pipeline definition $defId, not $PipelineId. " +
                   "Re-check the run URL, or drop -PipelineId and let ZED map each run to its own pipeline.")
        }
        try { $out.Add((Get-RunRecord -DefinitionId $defId -RunId $rid)) | Out-Null }
        catch { Write-Warning "Run $rid detail fetch failed: $($_.Exception.Message)" }
    }
    if ($out.Count -eq 0 -and $skipped.Count -gt 0) {
        throw ("Every supplied run ($($skipped -join ', ')) was authored by ZED itself. " +
               "Supply runs a human queued for a real release, or pass -IncludeSelfAuthored for diagnostics only.")
    }
    return ,@($out.ToArray())
}

# -- Discovery mode: list the pipeline's recent runs --
try {
    $list = Invoke-AdoJsonGet -RelativeApiPath "pipelines/$PipelineId/runs?api-version=7.1-preview.1"
} catch {
    throw "ADO pipeline $PipelineId run list failed: $($_.Exception.Message)"
}

$candidates = @($list.value)
if ($ResultFilter -ne 'any') {
    $candidates = @($candidates | Where-Object { $_.result -eq $ResultFilter })
}
$candidates = @($candidates | Where-Object { -not $excludedSet.ContainsKey([string]$_.id) })
$candidates = @($candidates | Select-Object -First $Top)

if (-not $candidates -or $candidates.Count -eq 0) {
    return ,@()
}

foreach ($run in $candidates) {
    try { $out.Add((Get-RunRecord -DefinitionId $PipelineId -RunId ([int]$run.id))) | Out-Null }
    catch { Write-Warning "Run $($run.id) detail fetch failed: $($_.Exception.Message)" }
}

return ,@($out.ToArray())
