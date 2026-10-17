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

.PARAMETER PipelineCatalogPath / GateScope / DeclaredParameters / LearnedModel
    Inputs for the P4 payload gate (Assert-ParameterPayload.ps1), which runs
    BEFORE the POST and throws rather than queue a payload that disagrees with
    the pipeline's YAML declaration or its learned model. Callers that already
    hold the declaration and model (Resolve-TemplateParams.ps1 returns both)
    should pass them to avoid a second catalog read.

.PARAMETER SkipPayloadGate
    Bypass the gate. Intended for tests that need to exercise the trigger path
    itself; using it to get past a genuine finding re-opens the exact defect the
    gate exists to prevent.

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
    [string]$CapturePath,
    [string]$PipelineCatalogPath,
    [string]$GateScope = 'production',
    [AllowNull()][object[]]$DeclaredParameters,
    [AllowNull()][object]$LearnedModel,
    # deploy-base releases: resources.builds fragment from Resolve-ReleaseBuild.ps1 -Action PinResources
    # (e.g. @{ bcm_service = @{ version = '<id>' } }) so the run consumes the exact release build.
    [AllowNull()][object]$BuildResources,
    [switch]$SkipPayloadGate
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

# ── P4: blocking payload gate ──
# The cheapest place to catch a malformed payload is before it exists in ADO
# history. A rejected queue is an opaque 400; a wrong-shaped value is accepted
# and deploys nothing at all. Both are caught here instead.
$gateResult = $null
if (-not $SkipPayloadGate) {
    $gateArgs = @{
        Payload     = $TemplateParameters
        PipelineKey = $PipelineKey
        Scope       = $GateScope
    }
    if ($PipelineCatalogPath) { $gateArgs.PipelineCatalogPath = $PipelineCatalogPath }
    if ($null -ne $DeclaredParameters) { $gateArgs.DeclaredParameters = $DeclaredParameters }
    if ($null -ne $LearnedModel)       { $gateArgs.Model              = $LearnedModel }
    # Deliberately not wrapped in try/catch: a rejected payload must stop the
    # step, not be recorded as a failed trigger and moved past.
    $gateResult = & (Join-Path $PSScriptRoot 'Assert-ParameterPayload.ps1') @gateArgs
}

# ── Queue the run with the REAL params ──
$queueUri = "$orgBase/pipelines/$PipelineId/runs?api-version=7.1-preview.1"
# Hashtable nested inside another hashtable serializes as its .NET object properties
# (IsFixedSize, SyncRoot, etc.) rather than its key-value pairs via ConvertTo-Json.
# Convert to PSCustomObject first to guarantee correct JSON serialization.
$tpObj = New-Object PSObject
foreach ($k in $TemplateParameters.Keys) {
    $tpObj | Add-Member -MemberType NoteProperty -Name $k -Value ([string]$TemplateParameters[$k])
}
$resourcesObj = [ordered]@{ repositories = [pscustomobject]@{ self = [pscustomobject]@{ refName = $SourceBranch } } }
if ($null -ne $BuildResources) { $resourcesObj.builds = $BuildResources }
$body = [pscustomobject]@{
    resources          = [pscustomobject]$resourcesObj
    templateParameters = $tpObj
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

# ── L-21: EV2 rollout cancellation after ADO cancel ──
# Production-scoped runs (Step 10/15) may have submitted an EV2 rollout.
# Cancelling the ADO build does NOT cancel the EV2 rollout — it continues deploying.
# Wire in Stop-Ev2Rollout.ps1 to catch active rollouts after ADO cancellation.
$ev2CancelResult = $null
$ev2CancelError  = $null
if ($triggered -and $cancelledAt -and $Step -in @(10, 15)) {
    $stopEv2Script = Join-Path $PSScriptRoot 'EV2\Stop-Ev2Rollout.ps1'
    if (Test-Path $stopEv2Script) {
        # Try to determine if this run had an EV2 rollout via Get-Ev2RolloutStatus.ps1
        $getStatusScript = Join-Path $PSScriptRoot 'EV2\Get-Ev2RolloutStatus.ps1'
        # Look up the EV2 service group from pipeline-catalog.json
        $ev2ServiceGroup = $null
        $ev2RolloutId    = $null
        try {
            $catalogDir = Join-Path (Get-Location) '.github/skills/zed-agent'
            $catFile    = Join-Path $catalogDir 'pipeline-catalog.json'
            if (Test-Path $catFile) {
                $catData = Get-Content $catFile -Raw | ConvertFrom-Json
                if ($catData.ev2ServiceGroups -and $catData.ev2ServiceGroups.PSObject.Properties[$PipelineKey]) {
                    $ev2ServiceGroup = $catData.ev2ServiceGroups.$PipelineKey
                }
            }
        } catch { }

        if ($ev2ServiceGroup) {
            # Attempt to read EV2 rollout status for this build
            try {
                if (Test-Path $getStatusScript) {
                    $statusResult = & $getStatusScript -BuildId $runId -ServiceGroup $ev2ServiceGroup -ErrorAction Stop
                    if ($statusResult -and $statusResult.RolloutId) {
                        $ev2RolloutId = $statusResult.RolloutId
                    }
                }
            } catch {
                # No rollout found for this build — this is expected for test runs
                # that cancel before EV2 submission. Not an error.
            }

            if ($ev2RolloutId) {
                # [UNVERIFIED — endpoint needs confirmation] inherited from Stop-Ev2Rollout.ps1
                # The EV2 cancel endpoint is unverified. Stop-Ev2Rollout.ps1 preserves the
                # EV2_CANCEL_UNVERIFIED failure mode — do NOT silently ignore failures.
                try {
                    $ev2CancelResult = & $stopEv2Script `
                        -RolloutId $ev2RolloutId `
                        -ServiceGroup $ev2ServiceGroup `
                        -BuildId "$runId" `
                        -VerifyTimeoutSeconds 60 `
                        -ErrorAction Stop
                } catch {
                    $ev2CancelError = $_.Exception.Message
                    # L-21: Fail LOUDLY — an uncancelled EV2 rollout is a production safety issue.
                    # Do NOT swallow this error. Surface it in the capture record and re-throw.
                    Write-Error "L-21 EV2 CANCELLATION FAILURE for build $runId, rollout $ev2RolloutId : $ev2CancelError"
                    throw "EV2_CANCEL_WIRING_FAILED: ADO build $runId was cancelled but the EV2 rollout $ev2RolloutId could not be cancelled/verified. Pipeline: $PipelineKey. Error: $ev2CancelError. IMMEDIATE ACTION: check the EV2 portal for rollout $ev2RolloutId status and cancel manually if still active."
                }
            }
        }
    }
}

# ── Build capture record ──
$record = [ordered]@{
    ts                 = (Get-Date).ToUniversalTime().ToString('o')
    step               = $Step
    pipelineKey        = $PipelineKey
    pipelineId         = $PipelineId
    sourceBranch       = $SourceBranch
    postedParameters   = $TemplateParameters
    pinnedBuilds       = $BuildResources
    runId              = $runId
    runUrl             = $runUrl
    triggered          = $triggered
    queuedAt           = $queuedAt
    cancelledAt        = $cancelledAt
    finalState         = $finalState
    ev2RolloutId       = $ev2RolloutId
    ev2CancelResult    = if ($ev2CancelResult) { $ev2CancelResult.cancelVerified } else { $null }
    ev2CancelError     = $ev2CancelError
    payloadGate        = if ($gateResult) {
        [ordered]@{ checked = $gateResult.checked; ok = $gateResult.ok; reason = $gateResult.reason }
    } else { [ordered]@{ checked = $false; ok = $null; reason = 'gate skipped (-SkipPayloadGate)' } }
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
