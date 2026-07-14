<#
.SYNOPSIS
    True-test-run helper. Triggers a REAL ADO pipeline run with the REAL
    templateParameters the agent computed for this step, captures exactly what
    was posted (params + runId + trigger success), then cancels the run within
    a few seconds so nothing actually deploys. Appends the capture record to
    .zed-agent/releases/<id>/test-run-capture.json.

.DESCRIPTION
    Used by the ZED "true test run" (testMode) for Step 2 (build), Step 5
    (canary) and Step 10 (roll-forward / prod pipelines). Unlike
    Invoke-PipelineDryRun.ps1 (which substitutes STUB values and targets a
    throwaway branch to validate that parameters PARSE), this script posts the
    agent's REAL resolved parameters against the REAL release branch so the
    development agent (ZedForge) can verify — against its requirements file —
    that ZED filled every parameter correctly and that the trigger succeeded.

    The run is cancelled within $CancelAfterSeconds (default 5s), which is well
    below ADO agent pickup time, so no SDP / EV2 work ever starts.

    The capture file is the machine-readable contract consumed by
    Test-RunRequirements.ps1 in the ZedForge skill.

    Auth: az login (Entra). ADO resource GUID 499b84ac-1321-427f-aa17-267ca6975798.

.PARAMETER Organization / Project
    ADO org + project (from service-config.json -> ado).

.PARAMETER PipelineId
    ADO pipeline definition id (from pipeline-catalog.json).

.PARAMETER PipelineKey
    Human key for the capture record: 'officialBuild', 'canary:<k>', 'production:<k>'.

.PARAMETER Step
    The ZED step number this trigger belongs to (2, 5 or 10).

.PARAMETER SourceBranch
    Full ref (e.g. refs/heads/Release-2604) — the REAL release branch.

.PARAMETER TemplateParameters
    Hashtable of the REAL resolved templateParameters the agent would post in a
    production run. Captured verbatim.

.PARAMETER ReleaseId
    Release id; used to locate the capture file. Auto-detected if omitted.

.PARAMETER CancelAfterSeconds
    Seconds between queue and cancel. Default 5.

.PARAMETER CapturePath
    Override for the capture file. Default .zed-agent/releases/<id>/test-run-capture.json.

.OUTPUTS
    PSCustomObject capture record (also appended to the capture file).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][int]$PipelineId,
    [Parameter(Mandatory)][string]$PipelineKey,
    [Parameter(Mandatory)][ValidateSet(2, 5, 10)][int]$Step,
    [Parameter(Mandatory)][string]$SourceBranch,
    [Parameter(Mandatory)][hashtable]$TemplateParameters,
    [string]$ReleaseId,
    [int]$CancelAfterSeconds = 5,
    [string]$CapturePath
)

$ErrorActionPreference = 'Stop'

# ── Resolve release id + capture path ──
if (-not $ReleaseId) {
    $relDir = Join-Path (Get-Location) '.zed-agent/releases'
    if (Test-Path $relDir) {
        $latest = Get-ChildItem $relDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { $ReleaseId = $latest.Name }
    }
    if (-not $ReleaseId) { throw "ReleaseId not supplied and none could be auto-detected under .zed-agent/releases." }
}
if (-not $CapturePath) {
    $CapturePath = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/test-run-capture.json"
}
$captureDir = Split-Path $CapturePath -Parent
if (-not (Test-Path $captureDir)) { New-Item -ItemType Directory -Path $captureDir -Force | Out-Null }

# ── Token ──
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) { throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com'." }
$headers = @{ Authorization = "Bearer $adoToken"; 'Content-Type' = 'application/json' }
$orgBase = "https://dev.azure.com/$Organization/$Project/_apis"

# ── Queue the run with the REAL params ──
$queueUri = "$orgBase/pipelines/$PipelineId/runs?api-version=7.1-preview.1"
$body = @{
    resources          = @{ repositories = @{ self = @{ refName = $SourceBranch } } }
    templateParameters = $TemplateParameters
} | ConvertTo-Json -Depth 16

$queuedAt   = (Get-Date).ToUniversalTime().ToString('o')
$runId      = $null
$runUrl     = $null
$triggered  = $false
$queueError = $null
try {
    $resp      = Invoke-RestMethod -Uri $queueUri -Method POST -Headers $headers -Body $body -ErrorAction Stop
    $runId     = $resp.id
    $runUrl    = "https://dev.azure.com/$Organization/$Project/_build/results?buildId=$runId"
    $triggered = $true
} catch {
    $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { '' }
    $queueError = "$($_.Exception.Message)$detail"
}

# ── Cancel (retry up to 3x) if the trigger succeeded ──
$cancelledAt = $null
$cancelError = $null
$finalState  = if ($triggered) { 'unknown' } else { 'queue-failed' }
if ($triggered) {
    Start-Sleep -Seconds $CancelAfterSeconds
    $cancelUri  = "$orgBase/build/builds/${runId}?api-version=7.0"
    $cancelBody = @{ status = 'cancelling' } | ConvertTo-Json
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-RestMethod -Uri $cancelUri -Method PATCH -Headers $headers -Body $cancelBody -ErrorAction Stop | Out-Null
            $cancelledAt = (Get-Date).ToUniversalTime().ToString('o')
            break
        } catch {
            $cancelError = "$($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }
    # Poll once for final state
    try {
        $detail = Invoke-RestMethod -Uri "$orgBase/build/builds/${runId}?api-version=7.0" -Headers $headers -ErrorAction Stop
        $finalState = if ($detail.status -eq 'completed') { $detail.result } else { $detail.status }
    } catch { }
}

# ── Build capture record ──
$record = [ordered]@{
    ts                 = (Get-Date).ToUniversalTime().ToString('o')
    step               = $Step
    pipelineKey        = $PipelineKey
    pipelineId         = $PipelineId
    sourceBranch       = $SourceBranch
    postedParameters   = $TemplateParameters
    runId              = $runId
    runUrl             = $runUrl
    triggered          = $triggered
    queuedAt           = $queuedAt
    cancelledAt        = $cancelledAt
    finalState         = $finalState
    error              = if ($queueError) { $queueError } elseif ($cancelError) { "cancel: $cancelError" } else { $null }
}

# ── Append to capture file (JSON array) ──
$existing = @()
if (Test-Path $CapturePath) {
    try {
        $parsed = Get-Content $CapturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($parsed) { $existing = @($parsed) }
    } catch { $existing = @() }
}
$existing += [pscustomobject]$record
($existing | ConvertTo-Json -Depth 16) | Set-Content $CapturePath -Encoding UTF8

# ── Audit ──
$auditFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/audit.jsonl"
@{ ts = $record.ts; event = 'test-run-trigger-and-cancel'; step = $Step; pipelineKey = $PipelineKey
   runId = $runId; triggered = $triggered; finalState = $finalState } |
    ConvertTo-Json -Compress | Add-Content $auditFile -Encoding UTF8

return [pscustomobject]$record
