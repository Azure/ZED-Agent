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
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][int]$PipelineId,
    [int]$Top = 3,
    [ValidateSet('succeeded','failed','canceled','any')]
    [string]$ResultFilter = 'succeeded',
    [int[]]$RunIds
)

$ErrorActionPreference = 'Stop'

# ── Acquire ADO-scoped token via az login ──
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) {
    throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com' and retry."
}
$headers = @{ Authorization = "Bearer $adoToken" }
$orgBase = "https://dev.azure.com/$Organization/$Project/_apis"

# ── Build the candidate run list ──
if ($PSBoundParameters.ContainsKey('RunIds') -and $RunIds -and $RunIds.Count -gt 0) {
    # Explicit-id mode: fetch each run directly, cross-check pipeline + result.
    $candidates = foreach ($rid in $RunIds) {
        $detailUri = "$orgBase/pipelines/$PipelineId/runs/${rid}?api-version=7.1-preview.1"
        try {
            $r = Invoke-RestMethod -Uri $detailUri -Headers $headers -ErrorAction Stop
        } catch {
            Write-Warning "Run ${rid}: fetch failed against pipeline $PipelineId — $($_.Exception.Message)"
            continue
        }
        # The Pipelines API scopes the URL to {pipelineId}; a wrong-pipeline run
        # comes back as 404 above. Belt-and-braces: also reject if pipeline.id
        # disagrees in case ADO ever loosens the URL scoping.
        if ($r.pipeline -and $r.pipeline.id -and ($r.pipeline.id -ne $PipelineId)) {
            Write-Warning "Run ${rid}: belongs to pipeline $($r.pipeline.id), not $PipelineId — skipped."
            continue
        }
        if (($ResultFilter -ne 'any') -and ($r.result -ne $ResultFilter)) {
            Write-Warning "Run ${rid}: result = '$($r.result)', expected '$ResultFilter' — skipped."
            continue
        }
        $r
    }
    $candidates = @($candidates)
} else {
    # Auto mode: list the most-recent runs, filter, take Top N.
    $listUri = "$orgBase/pipelines/$PipelineId/runs?api-version=7.1-preview.1"
    try {
        $list = Invoke-RestMethod -Uri $listUri -Headers $headers -ErrorAction Stop
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
    $detailUri = "$orgBase/pipelines/$PipelineId/runs/${runId}?api-version=7.1-preview.1"
    try {
        $detail = Invoke-RestMethod -Uri $detailUri -Headers $headers -ErrorAction Stop
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
        runUrl             = "https://dev.azure.com/$Organization/$Project/_build/results?buildId=$runId"
        finishedAt         = $detail.finishedDate
        sourceBranch       = $detail.resources.repositories.self.refName
        result             = $detail.result
        templateParameters = $tp
    }
}

return ,@($out)
