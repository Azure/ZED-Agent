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

# ── Dry-run execution gate (setupService only) ──
# Mechanically refuse status='pass' unless the Phase 4.12 dry-run actually ran
# for every consented pipeline. No owner prompt — downgrade and stamp the
# blocking phase so `run` can route the owner back to `setup-service group 4.12`.
if ($Stage -eq 'setupService' -and $Data['status'] -eq 'pass') {
    $dr = $Data['dryRun']
    $reason = $null
    if (-not $dr) {
        $reason = 'dryRun block missing'
    } elseif (-not $dr['executed']) {
        $reason = 'dryRun.executed != true'
    } elseif ([int]($dr['pipelinesQueued']) -lt [int]($dr['consented'])) {
        $reason = "dryRun.pipelinesQueued ($($dr['pipelinesQueued'])) < dryRun.consented ($($dr['consented']))"
    }
    if ($reason) {
        Write-Warning "setupService status='pass' refused: $reason. Downgrading to 'incomplete', lastGroup='4.12'."
        $Data['status'] = 'incomplete'
        $Data['lastGroup'] = '4.12'
        $Data['gateRefused'] = @{
            at     = (Get-Date).ToUniversalTime().ToString('o')
            reason = $reason
            resume = 'setup-service group 4.12'
        }
        # Mirror to audit.jsonl so the refusal is forensically recoverable.
        $auditPath = Join-Path (Split-Path $ReadinessPath -Parent) 'audit.jsonl'
        $auditRow = @{
            timestamp = $Data['gateRefused']['at']
            type      = 'readiness-gate-refused'
            stage     = 'setupService'
            reason    = $reason
            dryRun    = $dr
        } | ConvertTo-Json -Depth 8 -Compress
        Add-Content -Path $auditPath -Value $auditRow -Encoding UTF8
    }
}

$current[$Stage] = $Data

$json = $current | ConvertTo-Json -Depth 20
Set-Content -Path $ReadinessPath -Value $json -Encoding UTF8 -NoNewline
Add-Content -Path $ReadinessPath -Value "`n"

Write-Verbose "Wrote readiness.$Stage to $ReadinessPath"
return $ReadinessPath
