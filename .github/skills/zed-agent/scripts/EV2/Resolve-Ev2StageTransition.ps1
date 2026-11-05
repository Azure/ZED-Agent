<#
.SYNOPSIS
    Resolves stage notification values for one pipeline/cloud rollout, independent of API array order.

.DESCRIPTION
    Uses the standard SDP sequence, restricted to stages present in this rollout.
    Pass StageOrder from an authoritative stage map for a custom sequence.
    Unrecognized or inconsistent stages produce an unverified result and a warning;
    callers must not send stage completion or promotion notifications for that result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BatchStages,
    [string[]]$StageOrder = @(
        'Canary', 'ManagedValidation', 'Low', 'Medium', 'Heavy',
        'Day1', 'Day2', 'Day3', 'Day4', 'Day5',
        'Day6', 'Day7', 'Day8', 'Day9', 'Day10'
    )
)

$ErrorActionPreference = 'Stop'
$out = [pscustomobject]@{
    isVerified         = $false
    completedStageName = $null
    completedStageIndex = -1
    nextStageName      = 'Unverified - check EV2 portal'
    nextStageStatus    = $null
    allStagesCompleted = $false
    waitingForPromotion = $false
    orderedStages      = @()
    error              = $null
}

$problem = $null
$names = @($BatchStages | ForEach-Object { [string]$_.name })
if ($BatchStages.Count -eq 0) {
    $problem = 'No batch stages were returned.'
} elseif (@($names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    $problem = 'A batch stage has no name.'
} elseif (@($names | Sort-Object -Unique).Count -ne $names.Count) {
    $problem = 'Duplicate batch stage names were returned.'
} elseif (@($StageOrder | Sort-Object -Unique).Count -ne $StageOrder.Count) {
    $problem = 'StageOrder contains duplicate names.'
} else {
    $unknown = @($names | Where-Object { $_ -notin $StageOrder })
    if ($unknown.Count -gt 0) {
        $problem = "Stage order is unknown for: $($unknown -join ', '). Supply StageOrder from the rollout's authoritative stage map."
    }
}

if ($problem) {
    $out.error = $problem
    Write-Warning "EV2 stage transition unverified: $problem"
    return $out
}

$ordered = @(
    foreach ($name in $StageOrder) {
        $BatchStages | Where-Object { $_.name -eq $name }
    }
)
$out.orderedStages = $ordered
$success = @('Completed', 'Succeeded', 'Success')
$terminal = $success + @('Skipped')
$completedIndex = -1
for ($i = 0; $i -lt $ordered.Count; $i++) {
    if ($ordered[$i].status -in $success) { $completedIndex = $i }
}

# A later completion must not hide an earlier failed or unfinished stage.
for ($i = 0; $i -lt $completedIndex; $i++) {
    if ($ordered[$i].status -notin $terminal) {
        $out.error = "Stage '$($ordered[$i].name)' is not complete before completed stage '$($ordered[$completedIndex].name)'. Check the rollout's stage map and status."
        Write-Warning "EV2 stage transition unverified: $($out.error)"
        return $out
    }
}

$out.isVerified = $true
$out.completedStageIndex = $completedIndex
if ($completedIndex -ge 0) {
    $out.completedStageName = $ordered[$completedIndex].name
}
$out.allStagesCompleted = @($ordered | Where-Object { $_.status -notin $terminal }).Count -eq 0
$next = $ordered | Select-Object -Skip ($completedIndex + 1) |
    Where-Object { $_.status -notin $terminal } | Select-Object -First 1
if ($next) {
    $out.nextStageName = $next.name
    $out.nextStageStatus = $next.status
    if ($completedIndex -ge 0) {
        $current = $ordered[$completedIndex]
        $out.waitingForPromotion = $next.status -in @('Waiting', 'NotStarted', 'Queued') -and
            $current.completedRegions -eq $current.totalRegions
    }
} else {
    $out.nextStageName = 'None - rollout stages complete'
}

return $out
