<#
.SYNOPSIS
    Polls the SafeFly approval state for a given request.

.DESCRIPTION
    Queries the SafeFly approval state API and returns the current state
    along with a classification (approved, pending, rejected, invalidated).

.PARAMETER SafeFlyId
    The GUID of the SafeFly request to check.

.PARAMETER OrgName
    SafeFly org name. Default: "r2d".

.OUTPUTS
    PSCustomObject with: state, classification (Approved|Pending|Rejected|Invalidated), raw response.

.EXAMPLE
    $status = .\Get-SafeFlyApproval.ps1 -SafeFlyId "defd1ec8-b3ab-4584-8897-7a1402af6155"
    # $status.classification -eq "Pending"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SafeFlyId,
    [string] $OrgName = "r2d"
)

$ErrorActionPreference = "Stop"

$SafeFlyEndpoint   = "https://www.safefly.azure.com"
$SafeFlyResourceId = "api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6"

# --- Authenticate ---
$token = az account get-access-token --resource $SafeFlyResourceId --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire SafeFly API token." }

$headers = @{ Authorization = "Bearer $token" }

# --- Query approval state ---
$uri = "$SafeFlyEndpoint/api/SafeFlyRequest/approvalstate?orgName=$OrgName&requestId=$SafeFlyId"

try {
    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    throw "SafeFly approval state API returned HTTP $statusCode"
}

$state = $response.currentRequestState

# --- Classify the state ---
$approvedStates    = @("ApprovedForDeployment", "AutoApproved", "DeploymentInProgress", "DeploymentCompleted")
$pendingStates     = @("Unsubmitted", "Draft", "EngineeringDirectorPending", "ServiceManagerPending", "BuddyPending", "ReadyToDeployPending", "CvpPending")
$rejectedStates    = @("EngineeringDirectorRejected", "ServiceManagerRejected", "BuddyRejected", "CvpRejected")
$invalidatedStates = @("Archived", "Deleted", "DeploymentCancelled")

$classification = if ($state -in $approvedStates)    { "Approved" }
                  elseif ($state -in $pendingStates)  { "Pending" }
                  elseif ($state -in $rejectedStates) { "Rejected" }
                  elseif ($state -in $invalidatedStates) { "Invalidated" }
                  else { "Unknown" }

$result = [PSCustomObject]@{
    safeFlyId      = $SafeFlyId
    state          = $state
    classification = $classification
    rawResponse    = $response
}

$emoji = switch ($classification) {
    "Approved"    { "✅" }
    "Pending"     { "⏳" }
    "Rejected"    { "❌" }
    "Invalidated" { "❌" }
    default       { "❓" }
}
Write-Host "$emoji SafeFly #$SafeFlyId — State: $state ($classification)" -ForegroundColor $(
    switch ($classification) { "Approved" { "Green" } "Pending" { "Yellow" } default { "Red" } }
)

return $result
