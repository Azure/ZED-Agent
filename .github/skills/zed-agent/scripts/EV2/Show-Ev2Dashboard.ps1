<#
.SYNOPSIS
    Renders a rich terminal dashboard for EV2 rollout status across all pipelines and clouds.

.DESCRIPTION
    Aggregates rollout data from Get-Ev2RolloutStatus.ps1 for all 4 pipelines × all clouds
    (Prod, Fairfax, Mooncake) and renders a formatted terminal dashboard with per-pipeline
    cards, region progress bars, SDP stage grouping, and error highlights.

.PARAMETER RolloutData
    Hashtable of pipeline key → cloud → rollout result object.
    If not provided, the script renders a demo/empty dashboard.

.PARAMETER PipelineBuilds
    Hashtable of pipeline key → buildId. Used to auto-query rollouts.

.PARAMETER Clouds
    Array of clouds to query. Default: @("Prod", "Fairfax", "Mooncake").

.EXAMPLE
    # The agent calls this after gathering all rollout data:
    $data = @{}
    $data["SVC-SFMC"] = @{ Prod = $prodResult; Fairfax = $ffResult }
    Show-Ev2Dashboard -RolloutData $data

.EXAMPLE
    # Auto-query from build IDs:
    Show-Ev2Dashboard -PipelineBuilds @{ "SVC-SFMC" = "159822784"; "SVC2-SFMC" = "159830918" }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Data')]
    [hashtable] $RolloutData,

    [Parameter(Mandatory, ParameterSetName = 'FromBuilds')]
    [hashtable] $PipelineBuilds,

    [string[]] $Clouds = @("Prod", "Fairfax", "Mooncake"),

    [switch] $Compact,

    [Parameter()]
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Load service config ---
$cfg = & (Join-Path $PSScriptRoot '..\..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

# ── Load pipeline catalog for ServiceGroup mapping ──
$catalogPath = Join-Path (Split-Path (Split-Path $scriptDir)) "pipeline-catalog.json"
$catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
$sgMap = @{}
foreach ($prop in $catalog.ev2ServiceGroups.PSObject.Properties) {
    $sgMap[$prop.Name] = $prop.Value
}

# ── Auto-query mode: build rollout data from build IDs ──
if ($PSCmdlet.ParameterSetName -eq 'FromBuilds') {
    $getScript = Join-Path $scriptDir "Get-Ev2RolloutStatus.ps1"
    $RolloutData = @{}

    foreach ($pipeKey in $PipelineBuilds.Keys) {
        $buildId = $PipelineBuilds[$pipeKey]
        $sg = $sgMap[$pipeKey]
        if (-not $sg) { Write-Warning "No ServiceGroup mapping for pipeline '$pipeKey'"; continue }

        $RolloutData[$pipeKey] = @{}
        foreach ($cloud in $Clouds) {
            try {
                $result = & $getScript -BuildId $buildId -ServiceGroup $sg -RolloutInfra $cloud
                $RolloutData[$pipeKey][$cloud] = $result
            } catch {
                $RolloutData[$pipeKey][$cloud] = [PSCustomObject]@{
                    overallStatus  = "Error"
                    completedNodes = @(); failedNodes = @(); inProgressNodes = @(); waitingNodes = @()
                    suggestedActions = @("Query failed: $_")
                    portalUrl = ""
                }
            }
        }
    }
}

# ── Rendering helpers ──
$boxChars = @{
    TL = "╔"; TR = "╗"; BL = "╚"; BR = "╝"
    H = "═"; V = "║"; LT = "╠"; RT = "╣"
    Cross = "╬"; TopT = "╦"; BotT = "╩"
}

function Write-HLine([int]$width, [string]$left, [string]$right, [string]$fill = $boxChars.H) {
    Write-Host "$left$($fill * ($width - 2))$right" -ForegroundColor DarkGray
}

function Write-BoxLine([string]$text, [int]$width, [string]$color = "White") {
    $pad = $width - 4 - $text.Length
    if ($pad -lt 0) { $text = $text.Substring(0, $width - 7) + "..."; $pad = 0 }
    Write-Host "$($boxChars.V) " -ForegroundColor DarkGray -NoNewline
    Write-Host $text -ForegroundColor $color -NoNewline
    Write-Host "$(' ' * $pad) $($boxChars.V)" -ForegroundColor DarkGray
}

function Get-StatusEmoji([string]$status) {
    switch -Regex ($status) {
        'Completed|Succeeded|Success' { "✅" }
        'Failed|Error|Faulted'        { "❌" }
        'Running|InProgress|Executing' { "🔄" }
        'Waiting|Queued|NotStarted|Pending' { "⏳" }
        'Unknown'                      { "❓" }
        default                        { "⬚" }
    }
}

function Get-StatusColor([string]$status) {
    switch -Regex ($status) {
        'Completed|Succeeded|Success' { "Green" }
        'Failed|Error|Faulted'        { "Red" }
        'Running|InProgress|Executing' { "Yellow" }
        'Waiting|Queued|NotStarted|Pending' { "DarkGray" }
        default                        { "Gray" }
    }
}

function Get-ProgressBar([int]$completed, [int]$total, [int]$width = 20) {
    if ($total -eq 0) { return "[" + ("-" * $width) + "]" }
    $filled = [Math]::Floor(($completed / $total) * $width)
    $empty = $width - $filled
    return "[" + ("█" * $filled) + ("░" * $empty) + "]"
}

# ── Collect all SDP stages across all results for consistent ordering ──
$sdpOrder = [ordered]@{}
$stageOrderList = @("Canary", "ManagedValidation", "Low", "Medium", "Heavy", "Day1", "Day2", "Day3", "Day4", "Day5", "Day6", "Day7", "Day8", "Day9", "Day10")
foreach ($s in $stageOrderList) { $sdpOrder[$s] = $true }

# ── Render dashboard ──
$dashWidth = 110
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$pipelineOrder = @($cfg.pipelines.canary.PSObject.Properties.Name)

Write-Host ""
Write-HLine $dashWidth $boxChars.TL $boxChars.TR
Write-BoxLine "🚀 EV2 ROLLOUT DASHBOARD                                    $now" $dashWidth "Cyan"
Write-HLine $dashWidth $boxChars.LT $boxChars.RT

# ── Summary row ──
$totalCompleted = 0; $totalFailed = 0; $totalInProgress = 0; $totalWaiting = 0; $totalRollouts = 0
foreach ($pipeKey in $pipelineOrder) {
    if (-not $RolloutData.ContainsKey($pipeKey)) { continue }
    foreach ($cloud in $Clouds) {
        if (-not $RolloutData[$pipeKey].ContainsKey($cloud)) { continue }
        $r = $RolloutData[$pipeKey][$cloud]
        $totalCompleted += $r.completedNodes.Count
        $totalFailed += $r.failedNodes.Count
        $totalInProgress += $r.inProgressNodes.Count
        $totalWaiting += $r.waitingNodes.Count
        $totalRollouts++
    }
}
$totalRegions = $totalCompleted + $totalFailed + $totalInProgress + $totalWaiting

$summaryLine = "  Rollouts: $totalRollouts | Regions: ✅ $totalCompleted  ❌ $totalFailed  🔄 $totalInProgress  ⏳ $totalWaiting  (Total: $totalRegions)"
Write-BoxLine $summaryLine $dashWidth "White"
Write-HLine $dashWidth $boxChars.LT $boxChars.RT

# ── Per-pipeline cards ──
foreach ($pipeKey in $pipelineOrder) {
    if (-not $RolloutData.ContainsKey($pipeKey)) { continue }

    $sg = $sgMap[$pipeKey] ?? "Unknown"
    $sgShort = if ($sg -match '\.(\w+)\.ACTIVE$') { $Matches[1] } else { $sg }

    Write-BoxLine "  📦 $pipeKey ($sgShort)" $dashWidth "White"
    Write-HLine $dashWidth $boxChars.LT $boxChars.RT "─"

    foreach ($cloud in $Clouds) {
        if (-not $RolloutData[$pipeKey].ContainsKey($cloud)) { continue }
        $r = $RolloutData[$pipeKey][$cloud]

        $cloudEmoji = switch ($cloud) { "Prod" { "🌐" } "Fairfax" { "🏛️" } "Mooncake" { "🌙" } default { "☁️" } }
        $statusEmoji = Get-StatusEmoji $r.overallStatus
        $statusColor = Get-StatusColor $r.overallStatus
        $cCount = $r.completedNodes.Count
        $fCount = $r.failedNodes.Count
        $pCount = $r.inProgressNodes.Count
        $wCount = $r.waitingNodes.Count
        $tCount = $cCount + $fCount + $pCount + $wCount
        $bar = Get-ProgressBar $cCount $tCount 15

        # Build allNodes BEFORE stage grouping (bug fix: was referenced before populated)
        $allNodes = @()
        $allNodes += $r.completedNodes | ForEach-Object { [PSCustomObject]@{ name = $_.name; sdpNode = $_.sdpNode; status = "Succeeded"; error = $_.error } }
        $allNodes += $r.failedNodes | ForEach-Object { [PSCustomObject]@{ name = $_.name; sdpNode = $_.sdpNode; status = "Failed"; error = $_.error } }
        $allNodes += $r.inProgressNodes | ForEach-Object { [PSCustomObject]@{ name = $_.name; sdpNode = $_.sdpNode; status = "InProgress"; error = $_.error } }
        $allNodes += $r.waitingNodes | ForEach-Object { [PSCustomObject]@{ name = $_.name; sdpNode = $_.sdpNode; status = "Waiting"; error = $_.error } }

        # Filter out nodes with empty/blank names or sdpNode (ghost entries from gov-cloud)
        $allNodes = @($allNodes | Where-Object { $_.name -and $_.name.Trim() -and $_.sdpNode -and $_.sdpNode.Trim() })

        # Determine which stage is currently active (first non-complete stage)
        $allStageGroups = $allNodes | Group-Object -Property sdpNode | Sort-Object { $idx = $stageOrderList.IndexOf($_.Name); if ($idx -lt 0) { 99 } else { $idx } }
        $currentStage = ""
        $lastCompleteStage = ""
        foreach ($sg in $allStageGroups) {
            $sgComp = ($sg.Group | Where-Object status -eq 'Succeeded').Count
            if ($sgComp -eq $sg.Group.Count) { $lastCompleteStage = $sg.Name }
            else { if (-not $currentStage) { $currentStage = $sg.Name }; break }
        }
        if (-not $currentStage -and $lastCompleteStage) { $currentStage = $lastCompleteStage }

        $stageLabel = if ($currentStage -and $r.overallStatus -match 'Running|InProgress') { " @ $currentStage" } else { "" }

        # Cloud header line
        $cloudLine = "  $cloudEmoji $cloud  $statusEmoji $($r.overallStatus)$stageLabel  $bar  $cCount/$tCount regions"
        Write-BoxLine $cloudLine $dashWidth $statusColor

        if ($allNodes.Count -gt 0) {
            # Group by SDP stage
            $grouped = $allNodes | Group-Object -Property sdpNode

            foreach ($group in $grouped | Sort-Object { $idx = $stageOrderList.IndexOf($_.Name); if ($idx -lt 0) { 99 } else { $idx } }) {
                $stageName = $group.Name
                $stageNodes = $group.Group
                $stageTotal = $stageNodes.Count
                $stageCompCount = ($stageNodes | Where-Object status -eq 'Succeeded').Count
                $stageFailCount = ($stageNodes | Where-Object status -eq 'Failed').Count
                $stageIPCount = ($stageNodes | Where-Object status -eq 'InProgress').Count

                # Determine stage-level status emoji
                $stageEmoji = if ($stageFailCount -gt 0) { "❌" }
                              elseif ($stageIPCount -gt 0) { "🔄" }
                              elseif ($stageCompCount -eq $stageTotal) { "✅" }
                              else { "⏳" }

                $stageColor = if ($stageFailCount -gt 0) { "Red" }
                              elseif ($stageIPCount -gt 0) { "Yellow" }
                              elseif ($stageCompCount -eq $stageTotal) { "Green" }
                              else { "Gray" }

                # Build inline region list: completed names, then marked non-completed
                $completedNames = @($stageNodes | Where-Object status -eq 'Succeeded' | ForEach-Object { $_.name } | Where-Object { $_ })
                $failedNames = @($stageNodes | Where-Object status -eq 'Failed' | ForEach-Object { $_.name } | Where-Object { $_ } | ForEach-Object { "❌ $_" })
                $ipNames = @($stageNodes | Where-Object status -eq 'InProgress' | ForEach-Object { $_.name } | Where-Object { $_ } | ForEach-Object { "🔶 $_" })
                $waitNames = @($stageNodes | Where-Object status -eq 'Waiting' | ForEach-Object { $_.name } | Where-Object { $_ } | ForEach-Object { "⏳ $_" })

                $regionParts = @()
                if ($completedNames.Count -gt 0) { $regionParts += $completedNames -join ", " }
                $nonComplete = @($failedNames + $ipNames + $waitNames) | Where-Object { $_ }
                if ($nonComplete.Count -gt 0) {
                    $sep = if ($regionParts.Count -gt 0) { " | " } else { "" }
                    $regionParts += "$sep$($nonComplete -join ', ')"
                }
                $regionList = $regionParts -join ""

                # Header: "     Canary ✅ 2/2"
                $stageHeader = "     $stageName $stageEmoji $stageCompCount/$stageTotal"
                Write-BoxLine $stageHeader $dashWidth $stageColor

                # Region list — wrap to fit box width, indent under stage
                if ($regionList) {
                    $maxLineLen = $dashWidth - 14  # indent + box margins
                    $indent = "       "
                    $words = $regionList -split ', '
                    $lines = @()
                    $currentLine = ""
                    foreach ($word in $words) {
                        $candidate = if ($currentLine) { "$currentLine, $word" } else { $word }
                        if ($candidate.Length -gt $maxLineLen -and $currentLine) {
                            $lines += $currentLine
                            $currentLine = $word
                        } else {
                            $currentLine = $candidate
                        }
                    }
                    if ($currentLine) { $lines += $currentLine }

                    # Render: single line gets "(regions)", multi-line gets "(line1," / " line2," / " lineN)"
                    if ($lines.Count -eq 1) {
                        Write-BoxLine "$indent($($lines[0]))" $dashWidth $stageColor
                    } else {
                        for ($li = 0; $li -lt $lines.Count; $li++) {
                            if ($li -eq 0) {
                                Write-BoxLine "$indent($($lines[$li])," $dashWidth $stageColor
                            } elseif ($li -eq $lines.Count - 1) {
                                Write-BoxLine "$indent $($lines[$li]))" $dashWidth $stageColor
                            } else {
                                Write-BoxLine "$indent $($lines[$li])," $dashWidth $stageColor
                            }
                        }
                    }
                }
            }
        } else {
            Write-BoxLine "     (no region data)" $dashWidth "DarkGray"
        }
    }

    Write-HLine $dashWidth $boxChars.LT $boxChars.RT
}

# ── Errors & Suggested Actions ──
$allErrors = @()
$allActions = @()
foreach ($pipeKey in $pipelineOrder) {
    if (-not $RolloutData.ContainsKey($pipeKey)) { continue }
    foreach ($cloud in $Clouds) {
        if (-not $RolloutData[$pipeKey].ContainsKey($cloud)) { continue }
        $r = $RolloutData[$pipeKey][$cloud]
        foreach ($f in $r.failedNodes) {
            $allErrors += [PSCustomObject]@{ pipeline = $pipeKey; cloud = $cloud; region = $f.name; sdp = $f.sdpNode; error = $f.error }
        }
        foreach ($a in $r.suggestedActions) {
            $allActions += [PSCustomObject]@{ pipeline = $pipeKey; cloud = $cloud; action = $a }
        }
    }
}

if ($allErrors.Count -gt 0) {
    Write-BoxLine "  ❌ FAILURES ($($allErrors.Count))" $dashWidth "Red"
    Write-HLine $dashWidth $boxChars.LT $boxChars.RT "─"
    foreach ($err in $allErrors) {
        $errLine = "  $($err.pipeline) [$($err.cloud)] $($err.region) ($($err.sdp))"
        Write-BoxLine $errLine $dashWidth "Red"
        if ($err.error) {
            $errDetail = "    └─ $($err.error)"
            if ($errDetail.Length -gt ($dashWidth - 6)) { $errDetail = $errDetail.Substring(0, $dashWidth - 9) + "..." }
            Write-BoxLine $errDetail $dashWidth "DarkRed"
        }
    }
    Write-HLine $dashWidth $boxChars.LT $boxChars.RT
}

if ($allActions.Count -gt 0) {
    Write-BoxLine "  💡 SUGGESTED ACTIONS" $dashWidth "Cyan"
    Write-HLine $dashWidth $boxChars.LT $boxChars.RT "─"
    $actionNum = 1
    foreach ($act in $allActions) {
        $actLine = "  $actionNum. [$($act.pipeline)/$($act.cloud)] $($act.action)"
        if ($actLine.Length -gt ($dashWidth - 6)) { $actLine = $actLine.Substring(0, $dashWidth - 9) + "..." }
        Write-BoxLine $actLine $dashWidth "White"
        $actionNum++
    }
    Write-HLine $dashWidth $boxChars.LT $boxChars.RT
}

# ── Portal links ──
Write-BoxLine "  🔗 PORTAL LINKS" $dashWidth "DarkCyan"
Write-HLine $dashWidth $boxChars.LT $boxChars.RT "─"
foreach ($pipeKey in $pipelineOrder) {
    if (-not $RolloutData.ContainsKey($pipeKey)) { continue }
    foreach ($cloud in $Clouds) {
        if (-not $RolloutData[$pipeKey].ContainsKey($cloud)) { continue }
        $r = $RolloutData[$pipeKey][$cloud]
        if ($r.portalUrl) {
            $linkLine = "  $pipeKey [$cloud]: $($r.portalUrl)"
            if ($linkLine.Length -gt ($dashWidth - 6)) { $linkLine = $linkLine.Substring(0, $dashWidth - 9) + "..." }
            Write-BoxLine $linkLine $dashWidth "DarkCyan"
        }
    }
}

Write-HLine $dashWidth $boxChars.BL $boxChars.BR
Write-Host ""
