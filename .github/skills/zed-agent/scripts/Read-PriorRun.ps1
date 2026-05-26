<#
.SYNOPSIS
    Reads the last N successful runs of an ADO pipeline and returns a normalized
    record per run including templateParameters, sourceBranch, finishedAt, runUrl.

.DESCRIPTION
    Used by setup-service Group 11 (Phase 11.1) to learn the real-world parameter
    shape of a pipeline from production history rather than asking the release
    owner to recite it from memory.

    Auth: az login (Entra). Token is acquired on the fly with the ADO resource
    GUID (499b84ac-1321-427f-aa17-267ca6975798) — same pattern as
    Get-RegionMapping.ps1 and Get-Ev2RolloutStatus.ps1.

.OUTPUTS
    Array of PSCustomObjects (most recent first):
      runId, runUrl, finishedAt, sourceBranch, result, templateParameters

    Returns @() (empty array) when the pipeline has no matching runs.

.PARAMETER ResultFilter
    Optional. Set to 'succeeded' (default) to only return successful runs,
    or omit to return any result.

.PARAMETER RunIds
    Optional. When supplied, the script skips the "last N runs" listing
    entirely and fetches each run by id directly via
    GET /pipelines/{id}/runs/{runId}. Each run is still cross-checked
    against -PipelineId (mismatches are skipped with a warning) and
    -ResultFilter (mismatches are dropped). -Top is ignored in this mode.

.PARAMETER RunRefs
    Optional. Accepts either bare integer ids ("28471") or full ADO run URLs
    of form .../_build/results?buildId=<id>. Parsed ids are merged with -RunIds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][int]$PipelineId,
    [int]$Top = 3,
    [ValidateSet('succeeded','failed','canceled','any')]
    [string]$ResultFilter = 'succeeded',
    [int[]]$RunIds,
    [string[]]$RunRefs
)

$ErrorActionPreference = 'Stop'

# ── Acquire ADO-scoped token via az login ──
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) {
    throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com' and retry."
}
$headers = @{ Authorization = "Bearer $adoToken" }

function Get-AdoBaseCandidates {
    param([string]$Org,[string]$Proj)
    # Known org quirk: msazure/One can 404 on dev.azure.com for some build APIs,
    # while visualstudio.com succeeds with the same token.
    if ($Org -ieq 'msazure' -and $Proj -ieq 'One') {
        return @("https://msazure.visualstudio.com/$Proj", "https://dev.azure.com/$Org/$Proj")
    }
    return @("https://dev.azure.com/$Org/$Proj", "https://$Org.visualstudio.com/$Proj")
}

function Invoke-AdoJsonGet {
    param([string]$RelativeApiPath)
    $lastErr = $null
    foreach ($base in $adoBases) {
        $uri = "$base/_apis/$RelativeApiPath"
        try {
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -ErrorAction Stop
            if ($resp.Content) { return ($resp.Content | ConvertFrom-Json) }
            throw "Empty response body from $uri"
        } catch {
            $lastErr = $_.Exception.Message
            continue
        }
    }
    throw "ADO GET failed for '$RelativeApiPath' on all hosts: $lastErr"
}

function Parse-RunRefToId {
    param([string]$Ref)
    if (-not $Ref) { return $null }
    $s = $Ref.Trim()
    if ($s -match '^\d+$') { return [int]$s }
    if ($s -match '[\?&]buildId=(\d+)') { return [int]$Matches[1] }
    return $null
}

$adoBases = Get-AdoBaseCandidates -Org $Organization -Proj $Project
$browserBase = $adoBases[0]

# ── Build the candidate run list ──
@($RunRefs) | ForEach-Object {
    if (-not $_) { return }
    $rid = Parse-RunRefToId -Ref $_
    if (-not $rid) { Write-Warning "Could not parse run id from reference '$_' — expected integer or ...buildId=<id>." }
}

$requestedRunIds = @()
if ($PSBoundParameters.ContainsKey('RunIds') -and $RunIds) { $requestedRunIds += @($RunIds) }
if ($PSBoundParameters.ContainsKey('RunRefs') -and $RunRefs) {
    foreach ($rr in $RunRefs) {
        $rid = Parse-RunRefToId -Ref $rr
        if ($rid) { $requestedRunIds += $rid }
    }
}
$requestedRunIds = @($requestedRunIds | Select-Object -Unique)

if ($requestedRunIds -and $requestedRunIds.Count -gt 0) {
    # Explicit-id mode: fetch each run directly, cross-check pipeline + result.
    $candidates = foreach ($rid in $requestedRunIds) {
        # 1) Build API lookup: validates run exists and belongs to the target
        # pipeline definition, regardless of how the id was supplied (URL/int).
        try {
            $build = Invoke-AdoJsonGet -RelativeApiPath "build/builds/${rid}?api-version=7.1"
        } catch {
            Write-Warning "Run ${rid}: build lookup failed — $($_.Exception.Message)"
            continue
        }

        $defId = $null
        if ($build.definition -and $build.definition.id) { $defId = [int]$build.definition.id }
        if ($defId -and $defId -ne $PipelineId) {
            Write-Warning "Run ${rid}: belongs to pipeline definition $defId, not $PipelineId — skipped."
            continue
        }

        $buildResult = "$($build.result)"
        if (($ResultFilter -ne 'any') -and ($buildResult -ne $ResultFilter)) {
            Write-Warning "Run ${rid}: result = '$buildResult', expected '$ResultFilter' — skipped."
            continue
        }

        # 2) Pipeline run fetch keeps templateParameters/sourceBranch shape used
        # by downstream phases.
        try {
            Invoke-AdoJsonGet -RelativeApiPath "pipelines/$PipelineId/runs/${rid}?api-version=7.1-preview.1"
        } catch {
            Write-Warning "Run ${rid}: pipeline run detail fetch failed — $($_.Exception.Message)"
            continue
        }
    }
    $candidates = @($candidates)
} else {
    # Auto mode: list the most-recent runs, filter, take Top N.
    try {
        $list = Invoke-AdoJsonGet -RelativeApiPath "pipelines/$PipelineId/runs?api-version=7.1-preview.1"
    } catch {
        throw "ADO pipeline $PipelineId run list failed: $($_.Exception.Message)"
    }

    $candidates = @($list.value)
    if ($ResultFilter -ne 'any') {
        $candidates = @($candidates | Where-Object { $_.result -eq $ResultFilter })
    }
    $candidates = @($candidates | Select-Object -First $Top)
}

if (-not $candidates -or $candidates.Count -eq 0) {
    return ,@()
}

# ── For each candidate, fetch full run detail (templateParameters + variables) ──
$out = foreach ($run in $candidates) {
    $runId = $run.id
    try {
        $detail = Invoke-AdoJsonGet -RelativeApiPath "pipelines/$PipelineId/runs/${runId}?api-version=7.1-preview.1"
    } catch {
        Write-Warning "Run $runId detail fetch failed: $($_.Exception.Message)"
        continue
    }

    # templateParameters live under .templateParameters; variables under .variables.
    $tp = @{}
    if ($detail.templateParameters) {
        foreach ($p in $detail.templateParameters.PSObject.Properties) { $tp[$p.Name] = $p.Value }
    }

    [PSCustomObject]@{
        runId              = $runId
        runUrl             = "$browserBase/_build/results?buildId=$runId"
        finishedAt         = $detail.finishedDate
        sourceBranch       = $detail.resources.repositories.self.refName
        result             = $detail.result
        templateParameters = $tp
    }
}

return ,@($out)
