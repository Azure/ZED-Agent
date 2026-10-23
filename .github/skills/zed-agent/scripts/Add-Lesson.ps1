<#
.SYNOPSIS
    Appends a free-form lesson to .zed-agent/lessons-learned.md and mirrors a
    one-line JSONL row to .zed-agent/audit.jsonl. Counterpart to Add-Learning.ps1
    (which is for structured learnings into learnings.md).

.DESCRIPTION
    Behavior Rule 10 (see ZedAgent.agent.md) requires lessons to be captured
    IMMEDIATELY — after every bug fix, owner correction, unexpected branch of
    behavior, novel remediation, MCP/API quirk, or service-specific assumption
    that should be parameterized. This script exists so that "immediately"
    is cheap: one call, no markdown formatting.

    UTC timestamp is auto-stamped. The script appends to:
      .zed-agent/lessons-learned.md   (markdown, human-reviewable at teardown)
      .zed-agent/audit.jsonl          (one-line {"type":"lesson", ...} row)

    If lessons-learned.md does not exist, it is created with a header block.
    If audit.jsonl does not exist, it is created.

.PARAMETER Step
    The phase, command, or step where the lesson surfaced (e.g. "setup-service
    Phase 4.12 production dry-run", "Step 10 roll-forward", "Read-PriorRun.ps1").

.PARAMETER Symptom
    One-line description of what was observed. Required.

.PARAMETER RootCause
    Optional. One-line root cause if known.

.PARAMETER Fix
    Optional. One-line description of the fix applied or proposed.

.PARAMETER Source
    How the lesson was discovered. Defaults to 'agent-discovery'.

.EXAMPLE
    .\Add-Lesson.ps1 -Step "Phase 4.3 reference-run validation" `
        -Symptom "Read-PriorRun.ps1 -RunIds throws unknown-parameter error" `
        -RootCause "Script lacked -RunIds; SKILL prescribed it" `
        -Fix "Added -RunIds [int[]] with direct GET /runs/{id} branch"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Step,
    [Parameter(Mandatory)][string]$Symptom,
    [string]$RootCause,
    [string]$Fix,
    [ValidateSet('agent-discovery','owner-correction','pipeline-failure','mcp-quirk','api-quirk')]
    [string]$Source = 'agent-discovery'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

$stateDir       = Join-Path $repoRoot '.zed-agent'
$lessonsPath    = Join-Path $stateDir 'lessons-learned.md'
$auditPath      = Join-Path $stateDir 'audit.jsonl'

if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# --- lessons-learned.md (markdown append) ---
if (-not (Test-Path $lessonsPath)) {
    @"
# ZED Agent — Lessons Learned

Per ``ZedAgent.agent.md`` Behavior Rule 10: append a new entry **immediately** after
any insight (bug, gotcha, quirk, better default, workaround), with UTC timestamp,
step/command, symptom, root cause if known, and proposed fix. Never batch.
Append, never overwrite.

---
"@ | Set-Content -Path $lessonsPath -Encoding UTF8
}

$entry = @()
$entry += ""
$entry += "## $utc — $Step"
$entry += ""
$entry += "**Symptom**: $Symptom"
if ($RootCause) { $entry += ""; $entry += "**Root cause**: $RootCause" }
if ($Fix)       { $entry += ""; $entry += "**Fix**: $Fix" }
$entry += ""
$entry += "**Source**: $Source"
$entry += ""
$entry += "---"

$entry -join "`r`n" | Add-Content -Path $lessonsPath -Encoding UTF8

# --- audit.jsonl mirror ---
$row = [ordered]@{
    timestamp = $utc
    type      = 'lesson'
    step      = $Step
    symptom   = $Symptom
    rootCause = $RootCause
    fix       = $Fix
    source    = $Source
}
($row | ConvertTo-Json -Compress) | Add-Content -Path $auditPath -Encoding UTF8

Write-Host "Lesson recorded: $Step — $Symptom"
return [PSCustomObject]@{
    lessonsPath = $lessonsPath
    auditPath   = $auditPath
    timestamp   = $utc
}
