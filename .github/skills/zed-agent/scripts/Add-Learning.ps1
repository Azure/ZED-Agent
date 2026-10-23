<#
.SYNOPSIS
    Appends a learning entry to learnings.md.
.PARAMETER Category
    One of: pipeline, process, infrastructure, notification, parameter, config
.PARAMETER Learning
    The insight or correction discovered during this release.
.PARAMETER Source
    How the learning was discovered: owner-correction, pipeline-failure, agent-discovery
.PARAMETER ReleaseId
    Current release ID (e.g., "2026-04"). Auto-detected from .zed-agent if not provided.
#>
param(
    [Parameter(Mandatory)][string]$Category,
    [Parameter(Mandatory)][string]$Learning,
    [ValidateSet("owner-correction","pipeline-failure","agent-discovery")]
    [string]$Source = "owner-correction",
    [string]$ReleaseId
)

$repoRoot = git rev-parse --show-toplevel
$learningsPath = Join-Path $repoRoot ".github\zed-agent\learnings.md"

# Auto-detect release ID if not provided
if (-not $ReleaseId) {
    $releaseDirs = Get-ChildItem "D:\.zed-agent\releases" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($releaseDirs) { $ReleaseId = $releaseDirs[0].Name }
    else { $ReleaseId = "unknown" }
}

# Generate next ID
$nextNum = 1
if (Test-Path $learningsPath) {
    $lines = Get-Content $learningsPath | Where-Object { $_.Trim() }
    $nextNum = $lines.Count + 1
}

$entry = [ordered]@{
    id        = "L{0:D3}" -f $nextNum
    date      = (Get-Date -Format "yyyy-MM-dd")
    releaseId = $ReleaseId
    category  = $Category
    learning  = $Learning
    source    = $Source
    applied   = $false
}

$entry | ConvertTo-Json -Compress | Add-Content -Path $learningsPath -Encoding UTF8
Write-Host "Learning $($entry.id) added: $Learning"
return $entry
