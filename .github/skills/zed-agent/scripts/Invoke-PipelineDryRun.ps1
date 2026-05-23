<#
.SYNOPSIS
    Queues a real ADO pipeline run with the templateParameters from
    pipeline-catalog.json and cancels it within $CancelAfterSeconds. Used by
    setup-service Group 11 (Phase 11.2 / 11.3) to validate that the parameters
    learned during discovery are accepted by ADO without consuming a real
    deployment.

.DESCRIPTION
    Mirrors the queue+cancel pattern Step 15 test-mode already uses in
    production (see ZedAgent.agent.md Step 15) — POST a run, sleep, PATCH
    status=cancelling. Default 5 seconds is well below the typical ADO agent
    pickup time, so no actual deployment happens.

    Auth: az login (Entra). Token acquired with the ADO resource GUID.

    Reserved tokens in templateParameters are substituted with stub values
    BEFORE the POST so ADO sees concrete strings. The substitution table is
    inlined below so it can be audited and tweaked centrally.

.PARAMETER PipelineKey
    Either 'officialBuild', or a key from canary.<key> / production.<key>.
    Use 'canary:<key>' or 'production:<key>' for unambiguous selection.

.PARAMETER CatalogPath
    Path to pipeline-catalog.json.

.PARAMETER CancelAfterSeconds
    Seconds to wait between queue and cancel. Default 5.

.PARAMETER DryRunBranch
    Branch ref to use as the run's sourceBranch. Default: refs/heads/setup-service-dry-run.
    The branch does NOT need to exist — ADO validates the ref at agent-pickup
    time, which we never reach.

.OUTPUTS
    PSCustomObject:
      pipelineKey, pipelineId, runId, runUrl, queuedAt, cancelledAt,
      finalState, queuedParameters, error (when something failed)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$PipelineKey,
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [int]$CancelAfterSeconds = 5,
    [string]$DryRunBranch = 'refs/heads/setup-service-dry-run'
)

$ErrorActionPreference = 'Stop'

# ── Reserved-token stub values used ONLY during dry-runs ──
# These are intentionally inert: validateOnly=true means EV2 would no-op even
# if cancellation failed; currentBranch is the stub dry-run branch; stamp /
# region lists are empty so even if the run ever picked up nothing would deploy.
$stubs = @{
    '{{currentBranch}}'  = $DryRunBranch
    '{{excludeStamps}}'  = ''
    '{{pubRegions}}'     = ''
    '{{ffStamps}}'       = ''
    '{{ffRegions}}'      = ''
    '{{sdpType}}'        = 'Test'
    '{{validateOnly}}'   = 'true'
}

# ── Load catalog & resolve entry ──
if (-not (Test-Path $CatalogPath)) { throw "pipeline-catalog.json not found at $CatalogPath" }
$catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json

$entry = $null
$resolvedKey = $PipelineKey
if ($PipelineKey -eq 'officialBuild') {
    $entry = $catalog.officialBuild
} elseif ($PipelineKey -match '^(canary|production):(.+)$') {
    $section = $Matches[1]
    $key     = $Matches[2]
    if ($catalog.$section -and $catalog.$section.PSObject.Properties[$key]) {
        $entry = $catalog.$section.$key
        $resolvedKey = "$section.$key"
    }
} else {
    foreach ($section in @('canary','production')) {
        if ($catalog.$section -and $catalog.$section.PSObject.Properties[$PipelineKey]) {
            $entry = $catalog.$section.$PipelineKey
            $resolvedKey = "$section.$PipelineKey"
            break
        }
    }
}
if (-not $entry) { throw "Pipeline key '$PipelineKey' not found in $CatalogPath." }

# ── Substitute reserved tokens ──
$substituted = @{}
foreach ($p in $entry.templateParameters.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [string] -and $stubs.ContainsKey($v)) {
        $v = $stubs[$v]
    }
    $substituted[$p.Name] = $v
}

# ── Token ──
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) { throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com'." }
$headers = @{ Authorization = "Bearer $adoToken"; 'Content-Type' = 'application/json' }
$orgBase = "https://dev.azure.com/$Organization/$Project/_apis"

# ── Queue the run ──
$queueUri = "$orgBase/pipelines/$($entry.id)/runs?api-version=7.1-preview.1"
$body = @{
    resources = @{
        repositories = @{
            self = @{ refName = $DryRunBranch }
        }
    }
    templateParameters = $substituted
} | ConvertTo-Json -Depth 16

$queuedAt = (Get-Date).ToUniversalTime().ToString('o')
$runId = $null
$runUrl = $null
$queueError = $null
try {
    $resp = Invoke-RestMethod -Uri $queueUri -Method POST -Headers $headers -Body $body -ErrorAction Stop
    $runId  = $resp.id
    $runUrl = "https://dev.azure.com/$Organization/$Project/_build/results?buildId=$runId"
} catch {
    $queueError = "$($_.Exception.Message)"
    return [PSCustomObject]@{
        pipelineKey      = $resolvedKey
        pipelineId       = $entry.id
        runId            = $null
        runUrl           = $null
        queuedAt         = $queuedAt
        cancelledAt      = $null
        finalState       = 'queue-failed'
        queuedParameters = $substituted
        error            = $queueError
    }
}

# ── Sleep + cancel ──
Start-Sleep -Seconds $CancelAfterSeconds

$cancelUri = "$orgBase/build/builds/${runId}?api-version=7.0"
$cancelBody = @{ status = 'cancelling' } | ConvertTo-Json
$cancelledAt = $null
$cancelError = $null
$attempts = 0
$maxAttempts = 3
while ($attempts -lt $maxAttempts) {
    $attempts++
    try {
        Invoke-RestMethod -Uri $cancelUri -Method PATCH -Headers $headers -Body $cancelBody -ErrorAction Stop | Out-Null
        $cancelledAt = (Get-Date).ToUniversalTime().ToString('o')
        break
    } catch {
        $cancelError = "$($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}

# ── Poll once for final state ──
$finalState = 'unknown'
try {
    $detail = Invoke-RestMethod -Uri "$orgBase/build/builds/${runId}?api-version=7.0" -Headers $headers -ErrorAction Stop
    $finalState = if ($detail.status -eq 'completed') { $detail.result } else { $detail.status }
} catch { }

return [PSCustomObject]@{
    pipelineKey      = $resolvedKey
    pipelineId       = $entry.id
    runId            = $runId
    runUrl           = $runUrl
    queuedAt         = $queuedAt
    cancelledAt      = $cancelledAt
    finalState       = $finalState
    queuedParameters = $substituted
    error            = $cancelError
}
