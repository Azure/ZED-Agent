<#
.SYNOPSIS
    Read/filter the FREEFORM ZED lessons-learned backlog (learnings.md).
    Status (pending/implemented) is resolved from forge-state.json.

.PARAMETER Pending       Show only pending (not yet implemented) entries.
.PARAMETER Status        Filter by explicit status (pending|implemented).
.PARAMETER Full          Print the full entry text (default: a short preview).
.PARAMETER LearningsPath Override. Default <skill>/learnings/learnings.md.
.PARAMETER StatePath     Override. Default <skill>/state/forge-state.json.
.OUTPUTS  Array of { key, title, status, iteration, appliedTo, text }.
#>
[CmdletBinding()]
param(
    [switch]$Pending,
    [ValidateSet('pending', 'implemented')][string]$Status,
    [switch]$Full,
    [string]$LearningsPath,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LearningsStore.ps1')
if (-not $LearningsPath) { $LearningsPath = Join-Path $PSScriptRoot '..\learnings\learnings.md' }
if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot '..\state\forge-state.json' }

if (-not (Test-Path $LearningsPath)) {
    Write-Host "No learnings backlog found at $LearningsPath."
    return @()
}

$entries = @(Read-Learnings -Path $LearningsPath -StatePath $StatePath)
if ($Pending) { $entries = @($entries | Where-Object { $_.status -eq 'pending' }) }
if ($Status) { $entries = @($entries | Where-Object { $_.status -eq $Status }) }

$total = @(Read-Learnings -Path $LearningsPath -StatePath $StatePath)
Write-Host "`n=== Learnings ($($entries.Count) shown / $($total.Count) total; $(@($total | Where-Object status -eq 'pending').Count) pending) ==="
foreach ($e in $entries) {
    Write-Host ("  [{0}] [{1}] {2}" -f $e.key, $e.status.ToUpper(), $e.title)
    if ($Full) {
        ($e.text -split "`n") | ForEach-Object { Write-Host "      $_" }
    }
    else {
        $preview = ($e.text -replace '\s+', ' ')
        Write-Host "      $($preview.Substring(0, [Math]::Min(180, $preview.Length)))..."
    }
    if ($e.status -eq 'implemented' -and $e.appliedTo) { Write-Host "      applied (iter $($e.iteration)) -> $([string]::Join(', ', @($e.appliedTo)))" }
}
return $entries
