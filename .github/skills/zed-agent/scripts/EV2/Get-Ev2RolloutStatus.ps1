<#
.SYNOPSIS
    Queries EV2 REST API for rollout status and returns per-region diagnostics.

.DESCRIPTION
    Extracts the RolloutId from ADO pipeline build logs, calls the EV2 REST API
    with embed-detail=true, and parses the response to identify failed datacenters,
    error messages, and suggested remediation actions.

.PARAMETER BuildId
    The ADO build ID whose logs contain the EV2 RolloutId.

.PARAMETER ServiceGroup
    The EV2 ServiceGroup name (e.g., "Microsoft.Azure.Backup.<Service>.<Component>.ACTIVE").

.PARAMETER RolloutInfra
    The rollout infrastructure: Prod, Fairfax, Mooncake, USNat, USSec.

.PARAMETER RolloutId
    If the RolloutId is already known, pass it directly and skip log parsing.

.PARAMETER AdoOrg
    Azure DevOps organization. Default: loaded from service config.

.PARAMETER AdoProject
    Azure DevOps project. Default: loaded from service config.

.OUTPUTS
    PSCustomObject with: rolloutId, serviceGroup, overallStatus, portalUrl,
    completedNodes[], failedNodes[], inProgressNodes[], waitingNodes[],
    suggestedActions[]

.EXAMPLE
    $status = .\Get-Ev2RolloutStatus.ps1 -BuildId 12345678 -ServiceGroup "Microsoft.Azure.Backup.<Service>.<Component>.ACTIVE"
    $status.failedNodes | ForEach-Object { Write-Host "❌ $($_.name) — $($_.error)" }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'FromBuild')]
    [string] $BuildId,

    [Parameter(Mandatory)]
    [string] $ServiceGroup,

    [string] $RolloutInfra = "Prod",

    [Parameter(Mandatory, ParameterSetName = 'Direct')]
    [string] $RolloutId,

    [string] $AdoOrg,
    [string] $AdoProject,

    [string] $UserEmail = "",  # Corp email for SSO auto-login on gov-cloud portal

    [Parameter()]
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"

# --- Load service config ---
$cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

if (-not $AdoOrg)     { $AdoOrg     = $cfg.ado.organization }
if (-not $AdoProject) { $AdoProject = $cfg.ado.project }

# ── 1. Multi-cloud EV2 endpoints ──
$ev2Endpoints = @{
    Prod     = "https://azureservicedeploy.msft.net"
    Fairfax  = "https://azureservicedeploy.usgovcloudapi.net"
    Mooncake = "https://azureservicedeploy.chinacloudapi.cn"
}

# Gov-clouds that require portal scraping (REST API unreachable from CorpNet)
$govClouds = @('Fairfax', 'Mooncake')

# ── Helper: Extract actual deployment error from an EV2 Action ──
# Priority chain:
#   1. ActionOperationInfo.ErrorInfo.Message (direct EV2 error)
#   2. ResourceOperations[].StatusMessage (ARM deployment error — contains the REAL error for SFRP failures)
#   3. ResourceOperations[].ErrorInfo.EscalationInfo (generic contact/escalation info)
#   4. FallbackMessage
function Extract-ActionError {
    param(
        [Parameter(Mandatory)] $Action,
        [string] $FallbackMessage = "EV2 action failed"
    )
    $result = @{ summary = $null; detail = $null; code = $null; reason = $null }

    # Try 1: Direct ErrorInfo from the Action
    $errInfo = $Action.ActionOperationInfo.ErrorInfo
    if ($errInfo.Message) {
        $result.summary = $errInfo.Message
        $result.code = $errInfo.Code
        return $result
    }

    # Try 2: ResourceOperations[].StatusMessage — the actual ARM deployment error
    $failedRO = $Action.ResourceOperations | Where-Object { $_.ProvisioningState -eq 'Failed' } | Select-Object -First 1
    if ($failedRO -and $failedRO.StatusMessage) {
        $sm = $failedRO.StatusMessage.ToString()
        $result.detail = $sm

        # Parse error code from StatusMessage (e.g., "Code: ClusterChildResourceOperationFailed")
        if ($sm -match 'Code:\s*(\S+)') { $result.code = $Matches[1] }
        # Parse failure reason from embedded JSON (e.g., "FailureReason": "UpgradeDomainTimeout")
        if ($sm -match '"FailureReason"\s*:\s*"([^"]+)"') { $result.reason = $Matches[1] }
        # Parse failed upgrade domain if present
        $udName = $null
        if ($sm -match '"UpgradeDomainName"\s*:\s*"([^"]+)"') { $udName = $Matches[1] }

        # Build human-readable summary
        if ($result.reason) {
            $result.summary = "$($result.code) ($($result.reason)$(if ($udName) { " on $udName" }))"
        } elseif ($result.code) {
            $result.summary = $result.code
        } else {
            # Truncate StatusMessage for summary (first meaningful line)
            $firstLine = ($sm -split "`n" | Where-Object { $_.Trim() -match '\S' } | Select-Object -First 1).Trim()
            $result.summary = if ($firstLine.Length -gt 200) { $firstLine.Substring(0, 200) + "..." } else { $firstLine }
        }
        return $result
    }

    # Try 3: ErrorInfo escalation/contact metadata (generic, not the real error)
    if ($failedRO) {
        $roErr = $failedRO.ErrorInfo
        $escalation = $roErr.EscalationInfo ?? $roErr.ContactEmail ?? $failedRO.StatusCode
        if ($escalation) {
            $result.summary = $escalation
            return $result
        }
    }

    # Fallback
    $result.summary = $FallbackMessage
    return $result
}

# ── 2. Extract RolloutId from ADO build logs ──
# For Prod: search all logs for the first rollout ID
# For gov-clouds: search the specific FF:/MC: stage logs for that cloud's rollout ID
if (-not $RolloutId) {
    Write-Host "🔍 Extracting RolloutId from ADO build $BuildId logs..." -ForegroundColor Cyan

    $adoToken = az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" --query accessToken -o tsv 2>$null
    if (-not $adoToken) { throw "Failed to acquire ADO API token." }
    $adoHeaders = @{ Authorization = "Bearer $adoToken" }

    $found = $false
    $govSvcTreeId = $null
    $govServiceGroup = $null

    if ($RolloutInfra -in $govClouds) {
        # ── Gov-cloud: targeted extraction from the specific cloud's stage logs ──
        # Stage names use prefix "FF:" for Fairfax, "MC:" for Mooncake
        $cloudPrefix = switch ($RolloutInfra) { 'Fairfax' { 'FF:' } 'Mooncake' { 'MC:' } }
        Write-Host "   Looking for $cloudPrefix stages in ADO build timeline..." -ForegroundColor DarkCyan

        $timelineUri = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/build/builds/$BuildId/timeline?api-version=7.0"
        $timeline = Invoke-RestMethod -Uri $timelineUri -Headers $adoHeaders -ErrorAction Stop

        # Find records in the gov-cloud stage that have "Rollout Progress" or "Ev2Agentless" tasks
        $govStageIds = @($timeline.records | Where-Object {
            $_.type -eq 'Stage' -and $_.name -match "^${cloudPrefix}"
        } | Select-Object -ExpandProperty id)

        if ($govStageIds) {
            # Find log-producing tasks within these stages
            $rolloutTasks = $timeline.records | Where-Object {
                $_.parentId -in $govStageIds -or (
                    $_.type -eq 'Task' -and $_.name -match 'Rollout Progress|Ev2Agentless|EV2' -and $_.log
                )
            }

            # Walk the tree: Stage → Phase → Job → Task (ADO inserts Phase between Stage and Job)
            $govPhaseIds = @($timeline.records | Where-Object {
                $_.type -eq 'Phase' -and $_.parentId -in @($govStageIds)
            } | Select-Object -ExpandProperty id)

            # Jobs may be children of Phases or directly of Stages
            $parentIds = @($govStageIds) + $govPhaseIds
            $govJobIds = @($timeline.records | Where-Object {
                $_.type -eq 'Job' -and $_.parentId -in $parentIds
            } | Select-Object -ExpandProperty id)

            $govTasks = $timeline.records | Where-Object {
                $_.type -eq 'Task' -and $_.parentId -in $govJobIds -and $_.log
            }

            foreach ($task in $govTasks) {
                $logUrl = $task.log.url
                if (-not $logUrl) { continue }
                $logContent = Invoke-RestMethod -Uri $logUrl -Headers $adoHeaders -ErrorAction SilentlyContinue
                if (-not $logContent) { continue }

                # Parse portal URL: ev2portal.azure.net/#/rollouts/{Cloud}/{SvcTreeId}/{SG}/{RolloutId}
                if ($logContent -match 'ev2portal\.azure\.net[^\s]*#/rollouts?/(\w+)/([^/]+)/([^/\s]+)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                    $RolloutId = $Matches[4]
                    $govSvcTreeId = $Matches[2]
                    $govServiceGroup = [Uri]::UnescapeDataString($Matches[3])
                    $found = $true
                    Write-Host "   Found $RolloutInfra rollout: $RolloutId" -ForegroundColor DarkCyan
                    break
                }
                # Fallback: "Rollout ID: <GUID>"
                if ($logContent -match 'Rollout\s*ID[:\s]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                    $RolloutId = $Matches[1]
                    $found = $true
                    break
                }
            }
        }

        if (-not $found) {
            Write-Warning "No $RolloutInfra stage found in build $BuildId. This pipeline may not deploy to $RolloutInfra."
            return [PSCustomObject]@{
                rolloutId        = $null
                serviceGroup     = $ServiceGroup
                rolloutInfra     = $RolloutInfra
                overallStatus    = "NotDeployed"
                portalUrl        = $null
                completedNodes   = @()
                failedNodes      = @()
                inProgressNodes  = @()
                waitingNodes     = @()
                suggestedActions = @("Pipeline $BuildId has no $RolloutInfra stage. Check pipeline-catalog.json -> ev2CloudCoverage to see which clouds this pipeline key is configured to deploy to.")
                rawResponse      = $null
            }
        }
    } else {
        # ── Prod: search all build logs for rollout ID ──
        $logsUri = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/build/builds/$BuildId/logs?api-version=7.0"
        $logsList = Invoke-RestMethod -Uri $logsUri -Headers $adoHeaders -ErrorAction Stop

        foreach ($logEntry in $logsList.value) {
            $logContent = Invoke-RestMethod -Uri $logEntry.url -Headers $adoHeaders -ErrorAction SilentlyContinue
            if (-not $logContent) { continue }

            if ($logContent -match 'Rollout\s*ID[:\s]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                $RolloutId = $Matches[1]
                $found = $true
            }
            if (-not $found -and $logContent -match 'ev2portal\.azure\.net/#/rollouts/(\w+)/[^/]+/[^/]+/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
                $RolloutId = $Matches[2]
                $found = $true
            }
            if ($found) { break }
        }

        if (-not $found) {
            Write-Warning "Could not extract RolloutId from build $BuildId logs."
            $encodedSg = [Uri]::EscapeDataString($ServiceGroup)
            return [PSCustomObject]@{
                rolloutId        = $null
                serviceGroup     = $ServiceGroup
                overallStatus    = "Unknown"
                portalUrl        = "https://ev2portal.azure.net/#/?servicegroups=$encodedSg&daterange=1&rolloutinfra=$RolloutInfra"
                completedNodes   = @()
                failedNodes      = @()
                inProgressNodes  = @()
                waitingNodes     = @()
                suggestedActions = @("RolloutId not found in pipeline logs. Check the EV2 portal dashboard manually.")
                rawResponse      = $null
            }
        }
    }
    Write-Host "✅ Found RolloutId: $RolloutId" -ForegroundColor Green
}

# ── 3. Query EV2 — route by cloud ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ($RolloutInfra -in $govClouds) {
    # ── 3a. Gov-cloud: use Edge CDP portal proxy API (REST API unreachable from CorpNet) ──
    # Use the svcTreeId and serviceGroup extracted from the ADO logs if available.
    # Fallback order: log-extracted → pipeline-catalog.ev2ServiceTreeIds → service-config.serviceTreeIds.ev2
    # NEVER fall back to serviceTreeIds.safefly — SafeFly's GUID is unrelated to EV2's.
    $querySvcTreeId = $govSvcTreeId
    if (-not $querySvcTreeId -and $cfg.pipelines.ev2ServiceTreeIds) {
        $querySvcTreeId = $cfg.pipelines.ev2ServiceTreeIds.$RolloutInfra
    }
    if (-not $querySvcTreeId -and $cfg.serviceTreeIds.ev2) {
        $querySvcTreeId = $cfg.serviceTreeIds.ev2.$RolloutInfra
    }
    if (-not $querySvcTreeId) {
        throw "No EV2 ServiceTreeId configured for cloud '$RolloutInfra'. Populate pipeline-catalog.json -> ev2ServiceTreeIds.$RolloutInfra or service-config.json -> serviceTreeIds.ev2.$RolloutInfra."
    }
    $queryServiceGroup = $govServiceGroup ?? $ServiceGroup
    Write-Host "📡 Querying EV2 portal API for $RolloutInfra rollout $RolloutId..." -ForegroundColor Cyan

    # Ensure Edge CDP is running and playwright-core is installed
    $ensureScript = Join-Path $scriptDir "Ensure-EdgeCDP.ps1"
    & $ensureScript -Port 9223

    # Call the portal proxy API via Edge CDP
    $scraperScript = Join-Path $scriptDir "Invoke-Ev2PortalScrape.js"
    $scraperArgs = @(
        $scraperScript,
        "--cloud", $RolloutInfra,
        "--serviceTreeId", $querySvcTreeId,
        "--serviceGroup", $queryServiceGroup,
        "--rolloutId", $RolloutId,
        "--cdpUrl", "http://localhost:9223"
    )
    $scraperOutput = & node @scraperArgs 2>&1

    # Parse the scraper's JSON output
    $scraperResult = $null
    foreach ($line in $scraperOutput) {
        $lineStr = "$line".Trim()
        if ($lineStr.StartsWith('{')) {
            try { $scraperResult = $lineStr | ConvertFrom-Json } catch { }
            if ($scraperResult) { break }
        }
    }

    if (-not $scraperResult) {
        throw "EV2 portal scraper returned no parseable output for $RolloutInfra rollout $RolloutId. Raw output: $($scraperOutput -join "`n")"
    }

    if ($scraperResult.status -eq 'error') {
        $errCode = $scraperResult.code
        $errMsg  = $scraperResult.message
        if ($errCode -in @('AUTH_REQUIRED', 'AUTH_EXPIRED')) {
            # Return structured auth-failure object so the caller/agent can handle gracefully
            # (send notification email, render dashboard with partial data, etc.)
            return [PSCustomObject]@{
                rolloutId        = $RolloutId
                serviceGroup     = $ServiceGroup
                rolloutInfra     = $RolloutInfra
                overallStatus    = "AuthRequired"
                portalUrl        = $scraperResult.portalUrl ?? "https://ra.ev2portal.azure.net"
                completedNodes   = @()
                failedNodes      = @()
                inProgressNodes  = @()
                waitingNodes     = @()
                suggestedActions = @(
                    "Gov-cloud EV2 portal auth expired for $RolloutInfra.",
                    "The ZED agent uses Edge CDP (Chrome DevTools Protocol) to scrape $RolloutInfra rollout data from the EV2 portal because the REST API is unreachable from CorpNet.",
                    "To fix: Open Edge → navigate to https://ra.ev2portal.azure.net → sign in → then re-run the dashboard query."
                )
                error            = @{ code = $errCode; message = $errMsg }
            }
        }
        throw "EV2 portal scraper failed ($errCode): $errMsg"
    }

    # scraperResult.data contains the rollout JSON (same format as REST API)
    $rollout = $scraperResult.data
} else {
    # ── 3b. Prod/Public cloud: direct EV2 REST API ──
    $ev2Resource = $ev2Endpoints[$RolloutInfra] ?? $ev2Endpoints['Prod']
    $ev2Token = az account get-access-token --resource $ev2Resource --query accessToken -o tsv 2>$null
    if (-not $ev2Token) { throw "Failed to acquire EV2 API token for resource '$ev2Resource'. Ensure you are logged in with 'az login'." }
    $ev2Headers = @{ Authorization = "Bearer $ev2Token" }

    $ev2Base = "$ev2Resource/api"
    $encodedSg = [Uri]::EscapeDataString($ServiceGroup)
    $uri = "$ev2Base/rollouts/${RolloutId}?servicegroupname=$encodedSg&api-version=2024-02-01&embed-detail=true&embed-actionretries=true"

    Write-Host "📡 Querying EV2 API for rollout $RolloutId..." -ForegroundColor Cyan

    try {
        $rollout = Invoke-RestMethod -Uri $uri -Headers $ev2Headers -ErrorAction Stop
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        throw "EV2 API returned HTTP $statusCode for rollout $RolloutId. Verify ServiceGroup '$ServiceGroup' and RolloutInfra '$RolloutInfra'."
    }
}

# ── 4. Parse rollout response ──
# ServiceTreeId differs per cloud (extracted from ADO logs or use defaults)
$serviceTreeId = $null
if ($govSvcTreeId) {
    $serviceTreeId = $govSvcTreeId
} elseif ($cfg.pipelines.ev2ServiceTreeIds -and $cfg.pipelines.ev2ServiceTreeIds.$RolloutInfra) {
    $serviceTreeId = $cfg.pipelines.ev2ServiceTreeIds.$RolloutInfra
} elseif ($cfg.serviceTreeIds.ev2 -and $cfg.serviceTreeIds.ev2.$RolloutInfra) {
    $serviceTreeId = $cfg.serviceTreeIds.ev2.$RolloutInfra
}
if (-not $serviceTreeId) {
    throw "No EV2 ServiceTreeId configured for cloud '$RolloutInfra'. Populate pipeline-catalog.json -> ev2ServiceTreeIds.$RolloutInfra or service-config.json -> serviceTreeIds.ev2.$RolloutInfra. (SafeFly's serviceTreeId is intentionally NOT used as a fallback.)"
}
$portalUrl = "https://ra.ev2portal.azure.net/#/rollouts/$RolloutInfra/$serviceTreeId/$ServiceGroup/$RolloutId"

$result = [PSCustomObject]@{
    rolloutId        = $RolloutId
    serviceGroup     = $ServiceGroup
    rolloutInfra     = $RolloutInfra
    overallStatus    = $null
    portalUrl        = $portalUrl
    completedNodes   = @()
    failedNodes      = @()
    inProgressNodes  = @()
    waitingNodes     = @()
    batchStages      = @()   # Parent SDP stages (Canary, Day1, etc.) with batch-level status
    suggestedActions = @()
    rawResponse      = $rollout
}

# Determine overall status
$result.overallStatus = $rollout.Status ?? $rollout.RolloutStatus ?? "Unknown"

# EV2 response uses StageInfos[] with ChildStages[] for per-region details
$stages = $rollout.StageInfos ?? @()

# Extract batch-level (parent) stage info for stage transition tracking
foreach ($stage in $stages) {
    $stageName = $stage.StageName ?? "Unknown"
    if ($stageName -match '__STAGE_PRECHECK__$') { continue }
    # Parent stages don't contain a dot (e.g., "Canary", "Day1", "Day2")
    if (-not $stageName.Contains('.')) {
        $batchStatus = $stage.StageStatus ?? "Unknown"
        $childCount = ($stage.ChildStages | Measure-Object).Count
        $completedChildren = ($stage.ChildStages | Where-Object { $_.StageStatus -match 'Completed|Succeeded|Success' } | Measure-Object).Count
        $result.batchStages += [PSCustomObject]@{
            name              = $stageName
            status            = $batchStatus
            totalRegions      = $childCount
            completedRegions  = $completedChildren
        }
    }
}

foreach ($stage in $stages) {
    $stageName = $stage.StageName ?? "Unknown"
    # Skip parent stages (Canary, Day1 etc.) and __STAGE_PRECHECK__ entries
    if ($stageName -match '__STAGE_PRECHECK__$' -or -not $stageName.Contains('.')) { continue }

    # Region stages are like "Day1.australiasoutheast"
    $parts = $stageName -split '\.'
    $sdpBatch = $parts[0]       # e.g., "Canary", "Day1"
    $regionName = $parts[1]     # e.g., "australiasoutheast"
    if (-not $regionName -or $regionName -match '^\s*$') { continue }
    $stageStatus = $stage.StageStatus ?? "Unknown"

    $node = [PSCustomObject]@{
        name                = $regionName
        sdpNode             = $sdpBatch
        status              = $stageStatus
        stageStatus         = $stageStatus      # original EV2 StageStatus (always preserved)
        derivedStatus       = $null             # enriched from ResourceGroups actions (set below)
        error               = $null
        errorDetail         = $null
        errorCode           = $null
        errorReason         = $null
        retryCount          = 0
        hasPreviousFailures = $false
        isStale             = $false
        lastUpdated         = $null
    }

    # Check ChildStages for error details
    if ($stage.ChildStages) {
        $failedChild = $stage.ChildStages | Where-Object { $_.StageStatus -eq 'Failed' } | Select-Object -First 1
        if ($failedChild) {
            $node.error = $failedChild.StageName
        }
    }

    switch -Regex ($stageStatus) {
        'Completed|Succeeded|Success' { $result.completedNodes += $node }
        'Failed|Error|Faulted'        { $result.failedNodes += $node }
        'InProgress|Running|Executing' { $result.inProgressNodes += $node }
        'Waiting|Queued|NotStarted'    { $result.waitingNodes += $node }
        default                        { $result.waitingNodes += $node }
    }
}

# ── 4b. Enrich in-progress nodes from ResourceGroups action retries ──
# embed-actionretries=true exposes ALL retry actions per resource, letting us detect
# failures and stale deployments that StageInfos alone reports as "Running".
$resourceGroups = $rollout.ResourceGroups ?? @()
if ($resourceGroups.Count -gt 0 -and $result.inProgressNodes.Count -gt 0) {
    # Build region → actions lookup from ResourceGroups
    $regionActionsMap = @{}  # normalized-region → @{ actions = @(); latestAction = $null }
    foreach ($rg in $resourceGroups) {
        $rawLoc = ($rg.Location ?? '').Trim().ToLower()
        if (-not $rawLoc) { continue }
        # Normalize: Location can have duplicates like "switzerlandwest switzerlandwest"
        $normalizedRegion = ($rawLoc -split '\s+' | Select-Object -First 1)

        if (-not $regionActionsMap.ContainsKey($normalizedRegion)) {
            $regionActionsMap[$normalizedRegion] = @{ actions = [System.Collections.ArrayList]::new() }
        }

        foreach ($resource in ($rg.Resources ?? @())) {
            foreach ($action in ($resource.Actions ?? @())) {
                [void]$regionActionsMap[$normalizedRegion].actions.Add($action)
            }
        }
    }

    # Reclassify in-progress nodes that have evidence of failure or staleness
    $stillInProgress = @()
    foreach ($node in $result.inProgressNodes) {
        $regionKey = $node.name.ToLower().Trim()
        $regionData = $regionActionsMap[$regionKey]

        if (-not $regionData -or $regionData.actions.Count -eq 0) {
            $stillInProgress += $node
            continue
        }

        $allActions = $regionData.actions
        # Sort by start time descending to find latest action
        $sorted = $allActions | Sort-Object {
            $start = $_.ActionOperationInfo.StartTime ?? $_.ActionOperationInfo.StartTimeUtc ?? ''
            if ($start -and $start -ne '0001-01-01T00:00:00') { [DateTime]$start } else { [DateTime]::MinValue }
        } -Descending

        $latestAction  = $sorted | Select-Object -First 1
        $failedActions = @($sorted | Where-Object { $_.Status -match 'Failed|Error|Faulted' })
        $node.retryCount = $failedActions.Count
        $node.hasPreviousFailures = ($failedActions.Count -gt 0)

        # Extract last-updated timestamp from latest action
        $opInfo = $latestAction.ActionOperationInfo
        $lastUpdatedStr = $opInfo.LastUpdatedTime ?? $opInfo.LastUpdatedTimeUtc ?? $opInfo.EndTime ?? $opInfo.EndTimeUtc ?? ''
        if ($lastUpdatedStr) {
            $node.lastUpdated = $lastUpdatedStr
            try {
                $lastUpdatedDt = [DateTime]::Parse($lastUpdatedStr).ToUniversalTime()
                $age = [DateTime]::UtcNow - $lastUpdatedDt
                if ($age.TotalHours -gt 2) { $node.isStale = $true }
            } catch { <# non-parseable date, skip stale check #> }
        }

        # Determine derived status
        $latestStatus = ($latestAction.Status ?? '').Trim()
        $latestErrorInfo = $latestAction.ActionOperationInfo.ErrorInfo

        if ($latestStatus -match 'Failed|Error|Faulted') {
            # Latest action itself failed — definitive failure
            $node.derivedStatus = "Failed"
            $node.status = "Failed"
            $extracted = Extract-ActionError -Action $latestAction -FallbackMessage "EV2 action failed"
            $node.error = "$($extracted.summary) (attempt $($failedActions.Count))"
            $node.errorDetail = $extracted.detail
            $node.errorCode = $extracted.code
            $node.errorReason = $extracted.reason
            $result.failedNodes += $node
        }
        elseif ($latestStatus -match 'Running|InProgress' -and $node.isStale -and $node.hasPreviousFailures) {
            # Latest action "Running" but stale (>2h) AND has prior failures — likely stuck/failed
            $node.derivedStatus = "FailedStale"
            $node.status = "Failed"
            $prevAction = $failedActions | Select-Object -First 1
            $extracted = Extract-ActionError -Action $prevAction -FallbackMessage "Deployment stale"
            $node.error = "Stale >2h with $($failedActions.Count) prior failure(s): $($extracted.summary)"
            $node.errorDetail = $extracted.detail
            $node.errorCode = $extracted.code
            $node.errorReason = $extracted.reason
            $result.failedNodes += $node
        }
        elseif ($latestStatus -match 'Running|InProgress' -and $node.isStale) {
            # Stale but no prior failures — flag as stale warning, keep in-progress
            $node.derivedStatus = "RunningStale"
            $node.error = "Running but stale (no updates >2h)"
            $stillInProgress += $node
        }
        else {
            # Genuinely running or has prior failures but latest is actively running
            if ($node.hasPreviousFailures) {
                $node.derivedStatus = "RunningAfterRetry"
                $node.error = "Active retry ($($failedActions.Count) prior failure(s))"
            }
            $stillInProgress += $node
        }
    }
    $result.inProgressNodes = $stillInProgress
}

# Fallback: if no StageInfos, try legacy Steps format
if ($stages.Count -eq 0) {
    $steps = $rollout.RolloutSteps ?? $rollout.Steps ?? @()
    foreach ($step in $steps) {
        $stepName = $step.Name ?? "UnknownStep"
        $targets = $step.Targets ?? $step.DataCenters ?? @()
        foreach ($target in $targets) {
            $node = [PSCustomObject]@{
                name                = $target.Name ?? $target.DataCenter ?? "UnknownDC"
                sdpNode             = $stepName
                status              = $target.Status ?? "Unknown"
                stageStatus         = $target.Status ?? "Unknown"
                derivedStatus       = $null
                error               = $target.ErrorDetails ?? $target.Error ?? $null
                errorDetail         = $null
                errorCode           = $null
                errorReason         = $null
                retryCount          = 0
                hasPreviousFailures = $false
                isStale             = $false
                lastUpdated         = $null
            }
            switch -Regex ($node.status) {
                'Completed|Succeeded|Success' { $result.completedNodes += $node }
                'Failed|Error|Faulted'        { $result.failedNodes += $node }
                'InProgress|Running|Executing' { $result.inProgressNodes += $node }
                default                        { $result.waitingNodes += $node }
            }
        }
    }
}

if ($result.completedNodes.Count -eq 0 -and $result.failedNodes.Count -eq 0 -and
    $result.inProgressNodes.Count -eq 0 -and $result.waitingNodes.Count -eq 0 -and $rollout) {
    $result.suggestedActions += "No per-region details parsed. Check portal for details: $portalUrl"
}

# ── 5. Generate suggested actions for failures ──
foreach ($failed in $result.failedNodes) {
    $errorText = if ($failed.error) { $failed.error.ToString() } else { "No error details available" }
    $action = switch -Regex ($errorText) {
        'ClusterChildResourceOperationFailed|UpgradeDomainTimeout|ApplicationUpgradeFailed' {
            $detail = if ($failed.errorReason) { " ($($failed.errorReason))" } else { "" }
            "SF deployment failure in $($failed.name)$detail. Check cluster health in SFX portal. If the failing UD rotates across retries, this indicates a cluster-wide health issue — not a single-node problem. Contact: asksfrp@microsoft.com"
        }
        'HealthCheck|HealthCheckFailure'  { "SF health check failure in $($failed.name). Check SFX for unhealthy services/partitions blocking the upgrade." }
        'timeout|deadline|timed out'      { "ARM deployment timeout in $($failed.name). Check region health in ICM. Retry: re-trigger pipeline with PubRegions=$($failed.name)" }
        'quota|capacity|limit'            { "Quota/capacity issue in $($failed.name). Check subscription limits in Azure portal, then retry." }
        'conflict|lock|locked'            { "Resource lock conflict in $($failed.name). Check for active ICM/CCOA, wait for resolution, then retry." }
        'auth|forbidden|401|403|unauthorized' { "Auth failure for $($failed.name). Verify service principal permissions and certificate expiry." }
        'not\s*found|404'                 { "Resource not found in $($failed.name). Verify the deployment target exists and naming is correct." }
        'throttl|429|rate'                { "Throttling in $($failed.name). Wait 15-30 minutes, then retry. Consider reducing batch size." }
        default                           { "Failure in $($failed.name): $errorText. Check EV2 portal for full details." }
    }
    $result.suggestedActions += $action
}

# ── 6. Summary output ──
$emoji = switch -Regex ($result.overallStatus) {
    'Completed|Succeeded' { "✅" }
    'Failed|Error'        { "❌" }
    'Running|InProgress'  { "🔄" }
    default               { "❓" }
}

$completedCount = $result.completedNodes.Count
$failedCount    = $result.failedNodes.Count
$progressCount  = $result.inProgressNodes.Count
$waitingCount   = $result.waitingNodes.Count
$totalCount     = $completedCount + $failedCount + $progressCount + $waitingCount

Write-Host "$emoji EV2 Rollout $RolloutId — $($result.overallStatus)" -ForegroundColor $(
    switch -Regex ($result.overallStatus) { 'Completed|Succeeded' { "Green" } 'Failed|Error' { "Red" } default { "Yellow" } }
)
Write-Host "   Completed: $completedCount | Failed: $failedCount | In Progress: $progressCount | Waiting: $waitingCount (Total: $totalCount)" -ForegroundColor Gray
Write-Host "   Portal: $portalUrl" -ForegroundColor DarkCyan

if ($result.failedNodes.Count -gt 0) {
    Write-Host "`n   Failed regions:" -ForegroundColor Red
    foreach ($f in $result.failedNodes) {
        $retryInfo = if ($f.retryCount -gt 0) { " [retries: $($f.retryCount)]" } else { "" }
        $staleTag  = if ($f.isStale) { " ⏳STALE" } else { "" }
        Write-Host "   ❌ $($f.name) ($($f.sdpNode))${retryInfo}${staleTag} — $($f.error ?? 'No details')" -ForegroundColor Red
    }
}

if ($result.inProgressNodes | Where-Object { $_.isStale -or $_.hasPreviousFailures }) {
    Write-Host "`n   ⚠️  In-progress regions with warnings:" -ForegroundColor Yellow
    foreach ($ip in ($result.inProgressNodes | Where-Object { $_.isStale -or $_.hasPreviousFailures })) {
        $tags = @()
        if ($ip.isStale)             { $tags += "⏳STALE" }
        if ($ip.hasPreviousFailures) { $tags += "retries:$($ip.retryCount)" }
        Write-Host "   🔄 $($ip.name) ($($ip.sdpNode)) [$($tags -join ', ')] — $($ip.error ?? 'Running')" -ForegroundColor Yellow
    }
}

return $result
