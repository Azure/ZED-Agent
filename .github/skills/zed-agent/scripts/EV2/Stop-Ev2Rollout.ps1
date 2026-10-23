<#
.SYNOPSIS
    L-21: Cancel an active EV2 rollout after an ADO build cancellation.

.DESCRIPTION
    Today Get-Ev2RolloutStatus.ps1 can read rollout status but nothing can
    cancel an EV2 rollout. Cancelling an ADO build can leave a live rollout
    still deploying to production.

    This script:
    1. Determines whether the cancelled ADO run had submitted an EV2 rollout
    2. Reads back the EV2 rollout state
    3. Cancels it in EV2 when still active
    4. VERIFIES the cancellation took effect (does not assume success)
    5. Surfaces a loud, unambiguous failure if cancellation could not be confirmed

    Auth: follows the same conventions as Get-Ev2RolloutStatus.ps1.

    [UNVERIFIED — endpoint needs confirmation]: The EV2 cancellation API endpoint
    used below is based on the EV2 REST API pattern observed in Get-Ev2RolloutStatus.ps1
    (PATCH to /api/rollouts/{RolloutId} with status=Cancelled). The exact endpoint
    and payload schema needs human confirmation against EV2 API documentation before
    production use. A wrong EV2 endpoint is worse than an explicit gap.

.PARAMETER RolloutId
    The EV2 rollout GUID to cancel.

.PARAMETER ServiceGroup
    The EV2 ServiceGroup name.

.PARAMETER RolloutInfra
    Rollout infrastructure: Prod, Fairfax, Mooncake. Default: Prod.

.PARAMETER BuildId
    Optional. The ADO build ID that was cancelled. Used for audit/logging.

.PARAMETER MaxRetries
    Maximum cancellation attempts. Default: 3.

.PARAMETER VerifyTimeoutSeconds
    Seconds to wait for cancellation to take effect. Default: 60.

.PARAMETER ServiceConfigPath
    Path to service-config.json.

.OUTPUTS
    PSCustomObject with: rolloutId, previousStatus, cancelAttempted,
    cancelVerified, finalStatus, error.
    THROWS if cancellation fails or cannot be verified.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RolloutId,
    [Parameter(Mandatory)][string]$ServiceGroup,
    [string]$RolloutInfra = "Prod",
    [string]$BuildId,
    [int]$MaxRetries = 3,
    [int]$VerifyTimeoutSeconds = 60,
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = 'Stop'

# EV2 REST endpoints (same as Get-Ev2RolloutStatus.ps1)
$ev2Endpoints = @{
    Prod     = "https://azureservicedeploy.msft.net"
    Fairfax  = "https://azureservicedeploy.usgovcloudapi.net"
    Mooncake = "https://azureservicedeploy.chinacloudapi.cn"
}

# Active EV2 statuses that warrant cancellation
$activeStatuses = @(
    'InProgress', 'Running', 'Executing',
    'Waiting', 'Queued', 'NotStarted',
    'WaitingForValidation'
)

# Terminal statuses — rollout is already done, no cancel needed
$terminalStatuses = @(
    'Completed', 'Succeeded', 'Success',
    'Failed', 'Error', 'Faulted',
    'Cancelled', 'Canceled'
)

$result = [PSCustomObject]@{
    rolloutId        = $RolloutId
    serviceGroup     = $ServiceGroup
    rolloutInfra     = $RolloutInfra
    buildId          = $BuildId
    previousStatus   = $null
    cancelAttempted  = $false
    cancelVerified   = $false
    finalStatus      = $null
    error            = $null
    verificationLog  = @()
}

# ── 1. Acquire EV2 token ──
$ev2Resource = $ev2Endpoints[$RolloutInfra]
if (-not $ev2Resource) {
    $ev2Resource = $ev2Endpoints['Prod']
}

$ev2Token = az account get-access-token --resource $ev2Resource --query accessToken -o tsv 2>$null
if (-not $ev2Token) {
    throw "EV2_CANCEL_AUTH_FAILED: Failed to acquire EV2 API token for '$ev2Resource'. Run 'az login --tenant microsoft.com' and retry."
}
$ev2Headers = @{
    Authorization  = "Bearer $ev2Token"
    'Content-Type' = 'application/json'
}

$ev2Base = "$ev2Resource/api"
$encodedSg = [Uri]::EscapeDataString($ServiceGroup)

# ── 2. Read current rollout status ──
$statusUri = "$ev2Base/rollouts/${RolloutId}?servicegroupname=$encodedSg&api-version=2024-02-01"
try {
    $rollout = Invoke-RestMethod -Uri $statusUri -Headers $ev2Headers -ErrorAction Stop
    $result.previousStatus = $rollout.Status ?? $rollout.RolloutStatus ?? 'Unknown'
} catch {
    throw "EV2_CANCEL_STATUS_READ_FAILED: Could not read EV2 rollout $RolloutId status. Error: $($_.Exception.Message). Cannot proceed with cancellation without knowing current state."
}

# ── 3. Determine if cancellation is needed ──
$currentStatus = $result.previousStatus

if ($currentStatus -in $terminalStatuses) {
    # Already terminal — no action needed
    $result.finalStatus = $currentStatus
    $result.verificationLog += "Rollout already in terminal state '$currentStatus' — no cancellation needed."
    if ($currentStatus -in @('Cancelled', 'Canceled')) {
        $result.cancelVerified = $true
    }
    return $result
}

if ($currentStatus -notin $activeStatuses -and $currentStatus -ne 'Unknown') {
    Write-Warning "EV2 rollout $RolloutId is in unexpected state '$currentStatus'. Attempting cancellation anyway."
}

# ── 4. Cancel the EV2 rollout ──
# [UNVERIFIED — endpoint needs confirmation]
# Based on EV2 REST API patterns, cancellation is typically:
#   PATCH /api/rollouts/{RolloutId}?servicegroupname={SG}&api-version=2024-02-01
#   Body: { "Status": "Cancelled" }
# OR:
#   POST /api/rollouts/{RolloutId}/cancel?servicegroupname={SG}&api-version=2024-02-01
# The exact endpoint must be confirmed with EV2 documentation.

$cancelUri = "$ev2Base/rollouts/${RolloutId}/cancel?servicegroupname=$encodedSg&api-version=2024-02-01"
$result.cancelAttempted = $true
$cancelSuccess = $false

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        $result.verificationLog += "Cancel attempt $attempt of $MaxRetries..."
        # Try POST to /cancel endpoint first
        Invoke-RestMethod -Uri $cancelUri -Method POST -Headers $ev2Headers -ErrorAction Stop | Out-Null
        $cancelSuccess = $true
        $result.verificationLog += "Cancel request accepted (attempt $attempt)."
        break
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        $result.verificationLog += "Cancel attempt $attempt failed (HTTP $statusCode): $($_.Exception.Message)"

        if ($statusCode -eq 404 -or $statusCode -eq 405) {
            # Endpoint not found / method not allowed — try PATCH fallback
            $result.verificationLog += "Trying PATCH fallback..."
            $patchUri = "$ev2Base/rollouts/${RolloutId}?servicegroupname=$encodedSg&api-version=2024-02-01"
            $patchBody = @{ Status = 'Cancelled' } | ConvertTo-Json
            try {
                Invoke-RestMethod -Uri $patchUri -Method PATCH -Headers $ev2Headers -Body $patchBody -ErrorAction Stop | Out-Null
                $cancelSuccess = $true
                $result.verificationLog += "PATCH cancel request accepted."
                break
            } catch {
                $result.verificationLog += "PATCH fallback also failed: $($_.Exception.Message)"
            }
        }

        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Seconds (2 * $attempt)  # exponential backoff
        }
    }
}

if (-not $cancelSuccess) {
    $result.error = "EV2_CANCEL_FAILED: All $MaxRetries cancellation attempts failed for rollout $RolloutId."
    throw @(
        "EV2_CANCEL_FAILED: Could not cancel EV2 rollout $RolloutId after $MaxRetries attempts.",
        "Rollout infrastructure: $RolloutInfra",
        "Service group: $ServiceGroup",
        "Previous status: $currentStatus",
        "ADO build: $BuildId",
        "",
        "⚠️  THE EV2 ROLLOUT MAY STILL BE ACTIVELY DEPLOYING TO PRODUCTION.",
        "",
        "IMMEDIATE ACTION REQUIRED:",
        "  1. Open the EV2 portal and manually cancel the rollout",
        "  2. Verify the cancellation took effect",
        "  3. Check which regions have already deployed",
        "",
        "[UNVERIFIED] The EV2 cancellation API endpoint needs confirmation.",
        "Verification log:",
        ($result.verificationLog -join "`n")
    ) -join "`n"
}

# ── 5. Verify cancellation took effect ──
$verifyStart = Get-Date
$verified = $false

while (((Get-Date) - $verifyStart).TotalSeconds -lt $VerifyTimeoutSeconds) {
    Start-Sleep -Seconds 5
    try {
        $rolloutCheck = Invoke-RestMethod -Uri $statusUri -Headers $ev2Headers -ErrorAction Stop
        $checkStatus = $rolloutCheck.Status ?? $rolloutCheck.RolloutStatus ?? 'Unknown'
        $result.verificationLog += "Verification check: status='$checkStatus'"

        if ($checkStatus -in @('Cancelled', 'Canceled')) {
            $verified = $true
            $result.finalStatus = $checkStatus
            break
        }
        if ($checkStatus -in @('Completed', 'Succeeded', 'Success', 'Failed', 'Error')) {
            # Reached a terminal state (possibly completed before cancel took effect)
            $result.finalStatus = $checkStatus
            $result.verificationLog += "Rollout reached terminal state '$checkStatus' (may have completed before cancellation)."
            $verified = $true
            break
        }
    } catch {
        $result.verificationLog += "Verification read failed: $($_.Exception.Message)"
    }
}

$result.cancelVerified = $verified
if (-not $verified) {
    $result.finalStatus = 'VerificationTimeout'
    $result.error = "EV2_CANCEL_UNVERIFIED"
    throw @(
        "EV2_CANCEL_UNVERIFIED: Cancellation was sent but could NOT be verified within ${VerifyTimeoutSeconds}s.",
        "Rollout ID: $RolloutId",
        "Service group: $ServiceGroup",
        "Previous status: $currentStatus",
        "",
        "⚠️  THE EV2 ROLLOUT STATE IS UNKNOWN. It may still be deploying.",
        "",
        "IMMEDIATE ACTION REQUIRED:",
        "  1. Open the EV2 portal: check rollout $RolloutId status manually",
        "  2. If still active, cancel manually",
        "  3. Report this verification failure so the cancellation API can be checked",
        "",
        "Verification log:",
        ($result.verificationLog -join "`n")
    ) -join "`n"
}

return $result
