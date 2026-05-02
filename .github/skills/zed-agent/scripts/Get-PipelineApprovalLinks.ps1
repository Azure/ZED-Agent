function Get-PipelineApprovalLinks {
    <#
    .SYNOPSIS
        Extract EV2 approval links and rollout URLs from ADO pipeline build logs.
    .DESCRIPTION
        For each build, calls the ADO Build Timeline API to find stages waiting for
        approval checkpoints, then scans only logs from those stages for EV2 approval
        URLs (approval.azengsys.com) and rollout portal links (ra.ev2portal.azure.net).
        Links are correlated to stages via the timeline record parent chain (checkpoint
        → job/phase → stage), not by array-index matching.
    .PARAMETER Builds
        Array of hashtables with: pipelineName, buildId
    .PARAMETER AccessToken
        Pre-acquired ADO access token. If not provided, tries az CLI.
    .PARAMETER Organization
        ADO organization (default: msazure)
    .PARAMETER Project
        ADO project (default: One)
    .OUTPUTS
        Array of PSCustomObject with: pipelineName, buildId, buildUrl, stages[]
        Each stage has: name, state, status, approvalUrl, ev2RolloutUrl
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Builds,
        [string]$AccessToken,
        [string]$Organization = 'msazure',
        [string]$Project = 'One'
    )

    $results = @()
    $adoBase = "https://dev.azure.com/$Organization/$Project"

    # Acquire token once if not provided
    if (-not $AccessToken) {
        try {
            $raw = az account get-access-token --resource "https://dev.azure.com" --query accessToken -o tsv --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw -match '^eyJ') { $AccessToken = $raw.Trim() }
        } catch { }
    }

    $headers = if ($AccessToken) { @{ Authorization = "Bearer $AccessToken" } } else { $null }

    foreach ($build in $Builds) {
        $buildId = $build.buildId
        $pipelineName = $build.pipelineName
        $buildUrl = "$adoBase/_build/results?buildId=$buildId"

        $entry = [PSCustomObject]@{
            pipelineName = $pipelineName
            buildId      = $buildId
            buildUrl     = $buildUrl
            stages       = @()
            error        = $null
        }

        if (-not $headers) {
            $entry.error = "No access token available"
            $results += $entry; continue
        }

        # Step 1: Get build timeline — the source of truth for stage/job/checkpoint structure
        $timelineRecords = @()
        try {
            $timelineUrl = "$adoBase/_apis/build/builds/$buildId/timeline?api-version=7.1"
            $timeline = Invoke-RestMethod -Uri $timelineUrl -Headers $headers -ErrorAction Stop
            $timelineRecords = @($timeline.records)
        } catch {
            $entry.error = "Timeline API failed: $($_.Exception.Message)"
            $results += $entry; continue
        }

        # Build a parentId → record lookup for walking the ancestry chain
        $recordById = @{}
        foreach ($r in $timelineRecords) { if ($r.id) { $recordById[$r.id] = $r } }

        # Helper: walk parent chain from any record up to a Stage record
        function Get-StageAncestor($recordId) {
            $visited = [System.Collections.Generic.HashSet[string]]::new()
            $current = $recordId
            while ($current -and $recordById.ContainsKey($current)) {
                if (-not $visited.Add($current)) { break }  # cycle guard
                $rec = $recordById[$current]
                if ($rec.type -eq 'Stage') { return $rec }
                $current = $rec.parentId
            }
            return $null
        }

        # Step 2: Identify stages and detect which have pending approval checkpoints
        $stageRecords = @($timelineRecords | Where-Object { $_.type -eq 'Stage' })
        $checkpointRecords = @($timelineRecords | Where-Object { $_.type -eq 'Checkpoint' })

        # Map each checkpoint to its owning stage via parent chain
        $stagesWithPendingApprovals = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($cp in $checkpointRecords) {
            if ($cp.state -in @('inProgress', 'pending')) {
                $ownerStage = Get-StageAncestor $cp.parentId
                if ($ownerStage) { [void]$stagesWithPendingApprovals.Add($ownerStage.id) }
            }
        }

        # Step 3: Build stage entries
        $stageEntries = @{}  # stageId → stage entry object
        if ($stageRecords.Count -gt 0) {
            foreach ($stage in $stageRecords) {
                $status = if ($stage.result) { $stage.result }
                          elseif ($stagesWithPendingApprovals.Contains($stage.id)) { 'waiting-for-approval' }
                          elseif ($stage.state -eq 'inProgress') { 'in-progress' }
                          else { $stage.state }
                $se = [PSCustomObject]@{
                    name = $stage.name; state = $stage.state; result = $stage.result
                    status = $status; approvalUrl = $null; ev2RolloutUrl = $null
                }
                $entry.stages += $se
                $stageEntries[$stage.id] = $se
            }
        }

        # Step 4: Scan only logs from records under waiting stages (not all logs)
        # Build a set of log IDs that belong to waiting stages
        $logsToScan = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($r in $timelineRecords) {
            if ($r.log -and $r.log.id) {
                $ownerStage = Get-StageAncestor $(if ($r.type -eq 'Stage') { $r.id } else { $r.parentId })
                if ($ownerStage -and $stagesWithPendingApprovals.Contains($ownerStage.id)) {
                    [void]$logsToScan.Add([int]$r.log.id)
                }
            }
        }

        # Also map logId → stageId for correlating discovered links to stages
        $logToStageId = @{}
        foreach ($r in $timelineRecords) {
            if ($r.log -and $r.log.id -and $logsToScan.Contains([int]$r.log.id)) {
                $ownerStage = Get-StageAncestor $(if ($r.type -eq 'Stage') { $r.id } else { $r.parentId })
                if ($ownerStage) { $logToStageId[[int]$r.log.id] = $ownerStage.id }
            }
        }

        # Scan targeted logs
        foreach ($logId in $logsToScan) {
            $stageId = $logToStageId[$logId]
            $se = if ($stageId -and $stageEntries.ContainsKey($stageId)) { $stageEntries[$stageId] } else { $null }
            try {
                $logUrl = "$adoBase/_apis/build/builds/$buildId/logs/$($logId)?api-version=7.1"
                $logContent = Invoke-RestMethod -Uri $logUrl -Headers $headers -ErrorAction Stop

                # Approval URLs — assign directly to the owning stage
                $approvalMatches = [regex]::Matches($logContent, 'https://approval\.azengsys\.com/approvalRequest\?id=[A-Fa-f0-9]+')
                foreach ($m in $approvalMatches) {
                    if ($se -and -not $se.approvalUrl) { $se.approvalUrl = $m.Value }
                }

                # EV2 rollout URLs
                $ev2Matches = [regex]::Matches($logContent, 'https://ra\.ev2portal\.azure\.net/[^\s"''<>\)]+')
                foreach ($m in $ev2Matches) {
                    $cleaned = $m.Value.TrimEnd('.', ',', ';')
                    if ($se -and -not $se.ev2RolloutUrl) { $se.ev2RolloutUrl = $cleaned }
                }
            } catch {
                # Log individual failures but continue
                Write-Warning "Failed to scan log $logId for build $buildId`: $($_.Exception.Message)"
                continue
            }
        }

        # If no stages found from timeline, create a synthetic one
        if ($entry.stages.Count -eq 0) {
            $entry.stages += [PSCustomObject]@{
                name = 'Unknown'; state = 'unknown'; result = $null
                status = 'unknown'; approvalUrl = $null; ev2RolloutUrl = $null
            }
        }

        $results += $entry
    }

    return $results
}
