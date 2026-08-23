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
# SafeFly V1 writes deprecated (HTTP 410). V2 endpoints tried in order of preference.
# ⚠️ [UNVERIFIED] As measured 2026-08-23 none of these accept a write: V2-live → 405,
# V2-classic → 500, V1-classic → 410 ReadOnlyMode, and the migration guide does not resolve.
# These are best-guess shapes kept so the cascade works the moment SafeFly V2 goes live.
# Until then Step 13 fails loudly by design — never downgrade that to a soft pass.
$SafeFlyEndpoints = @(
    @{ Label = "V2-live"; Base = "https://safeflyv2.live.azure.com"; Path = "/api/v1.0/requests" }
    @{ Label = "V2-classic"; Base = "https://www.safefly.azure.com"; Path = "/api/RequestCreation/v2/requests" }
    @{ Label = "V1-classic"; Base = "https://www.safefly.azure.com"; Path = "/api/RequestCreation/v1/requests" }
)
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

# --- Reconcile targeted regions against SafeFly's accepted region enum ---
# SafeFly's region enum drifts behind ASC/Get-RegionMapping: some names differ and
# some newer regions aren't onboarded yet. Dropping the known-unsupported names
# prevents the R2D filing from 400ing whenever ASC adds a region SafeFly hasn't
# onboarded. (Ideal: fetch SafeFly's allowed list and intersect; this static list
# captures the drift observed 2026-07 during TEST-2026-07-i1 — extend as harvested.)
$safeFlyUnsupportedRegions = @(
    'Denmark East', 'India South Central', 'Northeast US 5', 'Saudi Arabia East',
    'Southeast Asia 3', 'Southeast US 5', 'Southwest US', 'USSec West Central',
    'West Central US FRE'
)
if ($TargetedRegions) {
    $before = @($TargetedRegions).Count
    $TargetedRegions = @($TargetedRegions | Where-Object { $safeFlyUnsupportedRegions -notcontains $_ })
    $dropped = $before - @($TargetedRegions).Count
    if ($dropped -gt 0) { Write-Host "  [SafeFly] dropped $dropped region(s) not in SafeFly's enum (submitting $(@($TargetedRegions).Count))" -ForegroundColor DarkYellow }
}

# --- Resolve SafeFly service group (service-agnostic: must come from config, never hard-coded) ---
$serviceGroupName = $cfg.safefly.serviceGroupName
if ([string]::IsNullOrWhiteSpace($serviceGroupName)) {
    throw "safefly.serviceGroupName is missing from service-config.json. It is the service's registered SafeFly/EV2 DeploymentTool service group (e.g. 'Backup (MAB)'). Add it via setup-service — ZED must not assume a service group."
}

# --- Build the full payload ---
$payload = @{
    OrgName       = $OrgName
    ServiceTreeID = $ServiceTreeId
    Tags          = @($cfg.safefly.tags)

    # People & risk
    ResponsibleEM       = $ReleaseOwnerAlias
    TeamAssessedRisk    = $TeamAssessedRisk
    AdditionalNotifiers = @($cfg.safefly.additionalNotifiers)

    # Deployment details
    DeploymentDetails = @{
        ADOOrganization      = $cfg.ado.organization
        ADOProject           = $cfg.ado.project
        ADOBuildId           = $BuildId
        DeploymentTool       = "EV2"
        DeploymentToolInputs = @{
            ServiceGroupName = $serviceGroupName
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
    HasSev2AlertingDetails      = "<a href='$($cfg.safefly.monitoringLink)'>Monitoring Dashboard</a>"
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
            PreProdTestingDetail = "https://apps.powerapps.com/play/e/e0ca1138-391d-e478-ac51-cc525c75c801/a/46095e8c-bb8a-4c92-bf51-a7ad2df04396?&source=portal"
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

# --- POST — try V2 endpoints first, then V1 ---
Write-Host "Submitting SafeFly R2D request..." -ForegroundColor Gray
$response = $null
$lastError = $null
foreach ($ep in $SafeFlyEndpoints) {
    $uri = "$($ep.Base)$($ep.Path)"
    Write-Host "  Trying $($ep.Label): $uri" -ForegroundColor Gray
    try {
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method POST `
            -Headers $headers `
            -Body $jsonBody
        Write-Host "  ✅ $($ep.Label) succeeded" -ForegroundColor Green
        break
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $detail     = $_.ErrorDetails.Message
        $lastError  = "SafeFly $($ep.Label) returned HTTP $statusCode — $detail"
        if ($statusCode -eq 410) {
            Write-Host "  ⚠️  $($ep.Label) HTTP 410 (read-only mode) — trying next endpoint" -ForegroundColor Yellow
        } elseif ($statusCode -eq 405) {
            Write-Host "  ⚠️  $($ep.Label) HTTP 405 (method not allowed) — trying next endpoint" -ForegroundColor Yellow
        } elseif ($statusCode -eq 500) {
            Write-Host "  ⚠️  $($ep.Label) HTTP 500 (server error) — trying next endpoint" -ForegroundColor Yellow
        } else {
            # Non-transient error (400, 401, 403, 422) — stop trying
            throw $lastError
        }
    }
}

if (-not $response) {
    throw "All SafeFly endpoints failed. Last error: $lastError"
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
