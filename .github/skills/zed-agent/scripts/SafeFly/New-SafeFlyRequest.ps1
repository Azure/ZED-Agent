<#
.SYNOPSIS
    Creates a SafeFly R2D (Ready to Deploy) request via the SafeFly REST API.

.DESCRIPTION
    Builds the full SafeFly payload from static defaults + dynamic per-release values,
    authenticates via Azure AD, and POSTs to the SafeFly RequestCreation API.

.PARAMETER BuildId
    ADO Build ID from the CloudBuild pipeline run (Step 2).

.PARAMETER BuildNumber
    Build number from the PROD pipeline run. Format: <BranchName>-<RunCount> (e.g., "Release-2604-2").
    This is auto-assigned by ADO when the production pipeline runs and stored in release.json during Step 10.

.PARAMETER ReleaseId
    Release identifier, e.g. "2026-04".

.PARAMETER ReleaseOwnerAlias
    Alias of the release owner (ResponsibleEM).

.PARAMETER TeamAssessedRisk
    Risk level. Default: "Low".

.PARAMETER DeploymentNature
    Array of deployment nature strings derived from commit analysis.
    Valid values: "New feature", "General bug fixes", "Config change", "Critical security fixes",
    "CRI fixes", "Monitoring/health signals", "Policy change", "Secrets/Certificate management",
    "Sev 1/2 repair", "OS/Image patch", "Other".
    Default: @("New feature", "General bug fixes").

.PARAMETER AnticipatedEndDays
    Days from now for AnticipatedEndTime. Default: end of current month.

.PARAMETER CommitExcelUrl
    SharePoint URL to the commit Excel file. Used as CustomerFacingChangeDescription.

.PARAMETER DryRun
    If set, outputs the payload JSON without submitting to the API.

.OUTPUTS
    PSCustomObject with safeFlyId, requestNumber, safeFlyUrl, requestStatus on success.
    Throws on failure.

.EXAMPLE
    $result = .\New-SafeFlyRequest.ps1 -BuildId 12345 -BuildNumber "Release-2604-2" -ReleaseId "2026-04" -ReleaseOwnerAlias "gireeraj" -SDPType "Standard SDP" -TargetedRegions @("East Asia", "Southeast Asia", "West US 2") -CommitExcelUrl "https://microsoft.sharepoint.com/..."
    # $result.safeFlyId, $result.requestNumber, etc.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BuildId,
    [Parameter(Mandatory)] [string] $BuildNumber,
    [Parameter(Mandatory)] [string] $ReleaseId,
    [Parameter(Mandatory)] [string] $ReleaseOwnerAlias,
    [string] $TeamAssessedRisk = "Low",
    [ValidateSet("New feature", "General bug fixes", "Config change", "Critical security fixes", "CRI fixes", "Monitoring/health signals", "Policy change", "Secrets/Certificate management", "Sev 1/2 repair", "OS/Image patch", "Other")]
    [string[]] $DeploymentNature = @("New feature", "General bug fixes"),
    [ValidateSet("Standard SDP", "Conservative SDP")]
    [string]   $SDPType = "Conservative SDP",
    [Parameter(Mandatory)]
    [string[]] $TargetedRegions,
    [int]    $AnticipatedEndDays = 0,
    [string] $CommitExcelUrl = "",
    [switch] $DryRun,

    [Parameter()]
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"

# --- Load service config ---
$cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

# --- Constants ---
$SafeFlyEndpoint   = "https://www.safefly.azure.com"
$SafeFlyResourceId = "api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6"
$OrgName           = "r2d"
$ServiceTreeId     = $cfg.serviceTreeIds.safefly

# --- Timestamps ---
$now               = (Get-Date).ToUniversalTime()
$startTime         = $now.ToString("yyyy-MM-ddTHH:mm:ss")
# AnticipatedEndTime: end of current month if AnticipatedEndDays is 0
if ($AnticipatedEndDays -gt 0) {
    $endTime = $now.AddDays($AnticipatedEndDays).ToString("yyyy-MM-ddTHH:mm:ss")
} else {
    $endOfMonth = (Get-Date -Year $now.Year -Month $now.Month -Day 1).AddMonths(1).AddDays(-1)
    $endTime = $endOfMonth.ToUniversalTime().ToString("yyyy-MM-ddT23:59:59")
}

# --- Derive title/description ---
$monthName   = $now.ToString("MMMM")                            # e.g. "April"
$shortYear   = $now.ToString("yy")                              # e.g. "26"
$title       = $cfg.safefly.titleTemplate -replace '\{serviceName\}', $cfg.service.name `
                   -replace '\{serviceDisplayName\}', $cfg.service.displayName `
                   -replace '\{month\}', $monthName -replace '\{yy\}', $shortYear
$description = if ($CommitExcelUrl) { "<a href='$CommitExcelUrl'>Commit Analysis</a>" } else {
    $cfg.safefly.descriptionTemplate -replace '\{serviceName\}', $cfg.service.name `
        -replace '\{releaseId\}', $ReleaseId
}

# --- Build test results URL ---
$testUrl = "https://$($cfg.ado.organization).visualstudio.com/$($cfg.ado.project)/_build/results?buildId=$BuildId&view=ms.vss-test-web.build-test-results-tab"

# --- Build the full payload ---
$payload = @{
    OrgName       = $OrgName
    ServiceTreeID = $ServiceTreeId
    Tags          = @($cfg.safefly.tags)

    # People & risk
    ResponsibleEM       = $ReleaseOwnerAlias
    TeamAssessedRisk    = $TeamAssessedRisk
    AdditionalNotifiers = ($cfg.safefly.additionalNotifiers -join '; ')

    # Deployment details
    DeploymentDetails = @{
        ADOOrganization      = $cfg.ado.organization
        ADOProject           = $cfg.ado.project
        ADOBuildId           = $BuildId
        DeploymentTool       = "EV2"
        DeploymentToolInputs = @{
            ServiceGroupName = "Backup (MAB)"
            BuildNumber      = $BuildNumber
        }
    }

    # Classification
    DeploymentType   = @{ DeploymentTypeName = "Regular" }
    DeploymentNature = $DeploymentNature
    SDPType          = $SDPType
    TargetedRegions  = $TargetedRegions

    # Impact & rollback
    ImpactType                  = @("None")
    ImpactDuration              = 0
    BlastRadius                 = "Single Cluster"
    Rollback                    = "DRI determines rollback or rollforward in real time based on the issue"
    RollbackDetails             = "Yes"
    RollbackRollforwardTesting  = $true
    RollbackTimeInMinutes       = 60

    # Alerting & compliance
    Sev2Alerting                = "Yes"
    HasSev2AlertingDetails      = "<a href='$($cfg.safefly.genevaMdmLink)'>Geneva MDM Monitors</a>"
    PayloadGoingToFairfax       = "yes"
    PayloadGoingToMooncake      = "yes"
    ImpactOfHoldingOffDeployment = "Next set of features and enhancements will not go in"
    SfiDetails                  = @{ SfiChange = "No" }
    CCOADetails                 = @{ IsCCOARequest = $false; CCOAEvent = ""; CCOAJustification = "" }
    HasRetake                   = $false

    # Pre-prod testing
    PreProdTesting = @(
        @{
            PreProdTestingType   = "End to End Testing"
            PreProdTestingDetail = "<a href='https://apps.powerapps.com/play/e/e0ca1138-391d-e478-ac51-cc525c75c801/a/46095e8c-bb8a-4c92-bf51-a7ad2df04396?&source=portal'>BVT Dashboard</a>"
        }
    )

    # Timing
    AnticipatedStartTime = $startTime
    AnticipatedEndTime   = $endTime

    # Title & description
    CustomerFacingChangeTitle       = $title
    CustomerFacingChangeDescription = $description

    # Deployment tracking
    DeploymentTrackingWorkspaceId      = ""
    DeploymentTrackingQueryId          = ""
    DeploymentTrackingQueryParameters  = @{
        ParameterName  = "BuildNumber"
        ParameterValue = $BuildNumber
    }
}

# Add Config change conditional fields when "Config change" is in DeploymentNature
if ($DeploymentNature -contains "Config change") {
    $payload["ConfigChangeTypes"]      = @("Service Config")
    $payload["GlobalConfigChange"]     = "no"
    $payload["ConfigChangeTypesOther"] = ""
}

$jsonBody = $payload | ConvertTo-Json -Depth 10

# --- Dry run ---
if ($DryRun) {
    Write-Host "=== DRY RUN — Payload ===" -ForegroundColor Cyan
    Write-Output $jsonBody
    return [PSCustomObject]@{
        safeFlyId            = "dry-run"
        safeFlyRequestNumber = 0
        safeFlyUrl           = "N/A"
        requestStatus        = "DryRun"
        payload              = $jsonBody
    }
}

# --- Authenticate ---
Write-Host "Acquiring SafeFly token..." -ForegroundColor Gray
$token = az account get-access-token --resource $SafeFlyResourceId --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire SafeFly API token. Run 'az login' first." }

# --- POST ---
Write-Host "Submitting SafeFly R2D request..." -ForegroundColor Gray
$headers = @{
    Authorization  = "Bearer $token"
    "Content-Type" = "application/json"
}

try {
    $response = Invoke-RestMethod `
        -Uri "$SafeFlyEndpoint/api/RequestCreation/v1/requests" `
        -Method POST `
        -Headers $headers `
        -Body $jsonBody
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $detail     = $_.ErrorDetails.Message
    throw "SafeFly API returned HTTP $statusCode — $detail"
}

# --- Parse response ---
$result = [PSCustomObject]@{
    safeFlyId            = $response.id
    safeFlyRequestNumber = $response.requestNumber
    safeFlyUrl           = $response.safeFlyUrl
    requestStatus        = $response.requestStatus
}

Write-Host "✅ SafeFly R2D request #$($result.safeFlyRequestNumber) created" -ForegroundColor Green
Write-Host "   URL: $($result.safeFlyUrl)" -ForegroundColor Gray

return $result
