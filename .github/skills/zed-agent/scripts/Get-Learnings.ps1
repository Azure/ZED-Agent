<#
.SYNOPSIS
    Reads learnings from learnings.md with optional filters.
.PARAMETER Unapplied
    Show only unapplied learnings (applied = false).
.PARAMETER Category
    Filter by category.
.PARAMETER ReleaseId
    Filter by release ID.
#>
param(
    [switch]$Unapplied,
    [string]$Category,
    [string]$ReleaseId
)

$repoRoot = git rev-parse --show-toplevel
$learningsPath = Join-Path $repoRoot ".github\zed-agent\learnings.md"

if (-not (Test-Path $learningsPath)) {
    Write-Host "No learnings file found. Nothing recorded yet."
    return @()
}

$entries = Get-Content $learningsPath | Where-Object { $_.Trim() } | ForEach-Object {
    $_ | ConvertFrom-Json
}

if ($Unapplied)  { $entries = $entries | Where-Object { -not $_.applied } }
if ($Category)   { $entries = $entries | Where-Object { $_.category -eq $Category } }
if ($ReleaseId)  { $entries = $entries | Where-Object { $_.releaseId -eq $ReleaseId } }

if ($entries.Count -eq 0) {
    Write-Host "No learnings match the filter criteria."
    return @()
}

Write-Host "`n=== Learnings ($($entries.Count) found) ==="
foreach ($e in $entries) {
    $status = if ($e.applied) { "APPLIED" } else { "PENDING" }
    Write-Host "`n  [$($e.id)] [$status] ($($e.category)) — $($e.date)"
    Write-Host "    $($e.learning)"
    if ($e.applied -and $e.appliedTo) {
        Write-Host "    Applied to: $($e.appliedTo)"
    }
}

return $entries
