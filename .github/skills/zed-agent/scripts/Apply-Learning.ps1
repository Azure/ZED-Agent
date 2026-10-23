<#
.SYNOPSIS
    Marks a learning as applied and records which file was changed.
    This script updates the learnings.md entry — the actual file changes
    are made by the agent based on the learning content.
.PARAMETER LearningId
    The learning ID to mark as applied (e.g., "L001").
.PARAMETER AppliedTo
    Comma-separated list of files that were changed (e.g., "SKILL.md, ZedAgent.agent.md").
#>
param(
    [Parameter(Mandatory)][string]$LearningId,
    [Parameter(Mandatory)][string]$AppliedTo
)

$repoRoot = git rev-parse --show-toplevel
$learningsPath = Join-Path $repoRoot ".github\zed-agent\learnings.md"

if (-not (Test-Path $learningsPath)) {
    Write-Error "No learnings file found."
    return
}

$lines = Get-Content $learningsPath
$updated = $false

$newLines = $lines | ForEach-Object {
    if ($_.Trim()) {
        $entry = $_ | ConvertFrom-Json
        if ($entry.id -eq $LearningId) {
            $entry.applied = $true
            $entry | Add-Member -NotePropertyName "appliedTo" -NotePropertyValue $AppliedTo -Force
            $entry | Add-Member -NotePropertyName "appliedDate" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd") -Force
            $updated = $true
            $entry | ConvertTo-Json -Compress
        } else {
            $_
        }
    } else {
        $_
    }
}

if ($updated) {
    $newLines | Set-Content -Path $learningsPath -Encoding UTF8
    Write-Host "Learning $LearningId marked as applied to: $AppliedTo"
} else {
    Write-Error "Learning $LearningId not found."
}
