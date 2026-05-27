<#
.SYNOPSIS
    Atomic writer for .zed-agent/readiness.json. Used by Test-PreFlight,
    setup-service, and setup to record their outcomes. The 'run' command
    reads this file via a separate Test-Readiness helper — it does NOT
    re-run the underlying check.

.PARAMETER Stage
    Which top-level section to update: 'preflight' | 'setupService' | 'setup' | 'inventory'.

.PARAMETER Data
    Hashtable of fields to merge into that section. Whatever keys are
    present overwrite the previous run's values; keys not supplied are
    preserved from the existing file.

.PARAMETER ReadinessPath
    Override the default location (.zed-agent/readiness.json in the cwd).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('preflight', 'setupService', 'setup', 'inventory')]
    [string]$Stage,

    [Parameter(Mandatory)]
    [hashtable]$Data,

    [string]$ReadinessPath
)

$ErrorActionPreference = 'Stop'

if (-not $ReadinessPath) {
    $baseDir = Join-Path (Get-Location) '.zed-agent'
    if (-not (Test-Path $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }
    $ReadinessPath = Join-Path $baseDir 'readiness.json'
}

# Load existing or seed empty
if (Test-Path $ReadinessPath) {
    try {
        $current = Get-Content $ReadinessPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "readiness.json exists but is not valid JSON — rewriting from scratch."
        $current = @{}
    }
} else {
    $current = @{}
}

# Ensure ranAt is always stamped
if (-not $Data.ContainsKey('ranAt')) {
    $Data['ranAt'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# ── Dry-run gate: setupService cannot be promoted to status='pass' unless the
# dry-run was both executed AND reviewed (Phase 4.11/4.12 outcome captured).
if ($Stage -eq 'setupService' -and ($Data['status'] -eq 'pass')) {
    $dr = $current['dryRun']
    $executed   = $dr -and $dr['executed']    -eq $true
    $reviewed   = $dr -and $dr['reviewed']    -eq $true
    $queued     = if ($dr -and $dr['pipelinesQueued']) { [int]$dr['pipelinesQueued'] } else { 0 }
    $consented  = if ($dr -and $dr['consented'])       { [int]$dr['consented'] }       else { 0 }
    if (-not $executed -or -not $reviewed -or ($queued -lt $consented)) {
        $reason = if (-not $executed) { 'dryRun.executed=false' }
                  elseif (-not $reviewed) { 'dryRun.reviewed=false' }
                  else { "pipelinesQueued ($queued) < consented ($consented)" }
        $resume = if (-not $reviewed -and $executed) { 'setup-service group 4.11' } else { 'setup-service group 4.10' }
        $audit  = Join-Path (Split-Path $ReadinessPath -Parent) 'audit.jsonl'
        $row = @{
            ts     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            event  = 'readiness-gate-refused'
            stage  = 'setupService'
            reason = $reason
            resume = $resume
        } | ConvertTo-Json -Compress -Depth 5
        Add-Content -Path $audit -Value $row
        throw "Write-Readiness refused setupService.status='pass': $reason. Resume: $resume."
    }
}

$current[$Stage] = $Data

$json = $current | ConvertTo-Json -Depth 20
Set-Content -Path $ReadinessPath -Value $json -Encoding UTF8 -NoNewline
Add-Content -Path $ReadinessPath -Value "`n"

Write-Verbose "Wrote readiness.$Stage to $ReadinessPath"
return $ReadinessPath
