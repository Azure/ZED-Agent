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
    [string] $OrgName = "r2d",
    [string] $ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"

# --- Classification vocabulary ---
# V1 states (and V1-migrated requests still listed by V2) plus the SafeFly V2 currentState
# values seen on live requests (2026-10: Approved, Draft, Submitted, Engineering Director
# Reviewed, R2D Reviewed, Rejected, Abandoned).
$approvedStates    = @("ApprovedForDeployment", "AutoApproved", "DeploymentInProgress", "DeploymentCompleted", "Approved")
$pendingStates     = @("Unsubmitted", "Draft", "EngineeringDirectorPending", "ServiceManagerPending", "BuddyPending", "ReadyToDeployPending", "CvpPending",
                       "Submitted", "Engineering Director Reviewed", "R2D Reviewed")
$rejectedStates    = @("EngineeringDirectorRejected", "ServiceManagerRejected", "BuddyRejected", "CvpRejected", "Rejected")
$invalidatedStates = @("Archived", "Deleted", "DeploymentCancelled", "Abandoned", "Cancelled")

# --- SafeFly V2 (preferred): the V1 approvalstate read API returns HTTP 410 since 2026-10 ---
$cfg = $null
try { $cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath } catch { $cfg = $null }
$useV2 = $cfg -and $cfg.safefly -and $cfg.safefly.PSObject.Properties['extendedRequest'] -and $cfg.safefly.extendedRequest -eq $true -and
    $cfg.safefly.PSObject.Properties['graphQlEndpoint'] -and -not [string]::IsNullOrWhiteSpace("$($cfg.safefly.graphQlEndpoint)")
if (-not $useV2) {
    # Original (pre-extendedRequest) V1 classification, unchanged for services that did not opt in.
    $approvedStates    = @("ApprovedForDeployment", "AutoApproved", "DeploymentInProgress", "DeploymentCompleted")
    $pendingStates     = @("Unsubmitted", "Draft", "EngineeringDirectorPending", "ServiceManagerPending", "BuddyPending", "ReadyToDeployPending", "CvpPending")
    $rejectedStates    = @("EngineeringDirectorRejected", "ServiceManagerRejected", "BuddyRejected", "CvpRejected")
    $invalidatedStates = @("Archived", "Deleted", "DeploymentCancelled")
}

if ($useV2) {
    $query = 'query GetRequestState($f: RequestFilterOptionsBaseInput!) { requests(pageSize: 1, filter: $f) { totalCount data { id displayId currentState activeStageNames buildVersion } } }'
    $data = & (Join-Path $PSScriptRoot 'Invoke-SafeFlyGraphQL.ps1') -Query $query `
        -Variables @{ f = @{ objectId = @{ equalTo = $SafeFlyId } } } -ServiceConfigPath $ServiceConfigPath
    $req = @($data.requests.data) | Select-Object -First 1
    if (-not $req) { throw "SafeFly V2: request '$SafeFlyId' not found (requests(filter: objectId) returned no rows)." }
    $response = $req
    $state = "$($req.currentState)"
} else {

$SafeFlyEndpoint   = "https://www.safefly.azure.com"
$SafeFlyResourceId = "api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6"

# --- Authenticate ---
$token = az account get-access-token --resource $SafeFlyResourceId --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire SafeFly API token." }

$headers = @{ Authorization = "Bearer $token" }

# --- Query approval state ---
$uri = "$SafeFlyEndpoint/api/SafeFlyRequest/approvalstate?orgName=$OrgName&requestId=$SafeFlyId"

try {
    $rawResp = Invoke-WebRequest -Uri $uri -Method GET -Headers $headers -UseBasicParsing
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    throw "SafeFly approval state API returned HTTP $statusCode"
}

$contentType = if ($rawResp.Headers['Content-Type']) { ($rawResp.Headers['Content-Type'] -split ';')[0].Trim() } else { '' }
if ($contentType -eq 'text/html' -or $rawResp.Content -match '^\s*<!DOCTYPE') {
    throw "SAFEFLY_HTML_RESPONSE: SafeFly returned Content-Type '$contentType' instead of JSON at $uri. Endpoint may be wrong or SPA shell was served."
}
$response = $rawResp.Content | ConvertFrom-Json

$state = $response.currentRequestState
}

# --- Classify the state ---
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
