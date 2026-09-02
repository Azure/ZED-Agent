<#
.SYNOPSIS
    Detect the most recent completed release branch in a target deployment repo,
    to use as previousBranch in ZedForge validation runs.

.DESCRIPTION
    ZedForge cuts a test branch from develop and passes it to ZED as currentBranch.
    If previousBranch is also set to develop, git log <develop>..<branch> returns
    an empty set and Step 4 (commit collection) always sees 0 commits — the full
    classification/nature-tagging path is never exercised.

    This script resolves the most recent COMPLETED release branch (e.g.
    releases/prot2607 when the current month is 2608) by:
    1. Reading ado.branchPrefix from service-config.json
    2. Listing remote branches matching that prefix
    3. Filtering to YYMM-pattern branches (excludes _hotfix, _az, rollback, etc.)
    4. Returning the latest one that is NOT the current month

    Returns a string branch name (without "origin/" prefix) or $null if none found.

.PARAMETER TargetRepo
    Path to the target deployment repo.

.PARAMETER BranchPrefix
    Branch prefix override (e.g. "releases/prot"). Auto-detected from
    service-config.json when omitted.

.PARAMETER CurrentYYMM
    Current release month in YYMM format (e.g. "2608"). Auto-detected from
    the current date when omitted. Used to exclude the in-progress release.
#>
[CmdletBinding()]
param(
    [string]$TargetRepo,
    [string]$BranchPrefix,
    [string]$CurrentYYMM
)

$ErrorActionPreference = 'Stop'

if (-not $TargetRepo) {
    $TargetRepo = (Get-Location).Path
}
if (-not (Test-Path $TargetRepo)) {
    throw "TargetRepo not found: $TargetRepo"
}

# Auto-detect branch prefix from service-config.json
if (-not $BranchPrefix) {
    $cfgPath = Join-Path $TargetRepo '.github\skills\zed-agent\service-config.json'
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $BranchPrefix = $cfg.ado.branchPrefix
    }
    if (-not $BranchPrefix) {
        Write-Warning "Get-PreviousBranch: branchPrefix not found in service-config.json; defaulting to 'releases/prot'"
        $BranchPrefix = 'releases/prot'
    }
}

# Auto-detect current YYMM (e.g. 2608 for August 2026)
if (-not $CurrentYYMM) {
    $CurrentYYMM = (Get-Date).ToString('yyMM')
}

# Fetch + list remote branches matching the prefix
Push-Location $TargetRepo
try {
    # Refresh remote refs quietly
    git fetch --prune origin 2>$null | Out-Null

    $remoteBranches = git branch -r --list "origin/$BranchPrefix*" 2>$null
    if (-not $remoteBranches) {
        Write-Warning "Get-PreviousBranch: no remote branches found matching 'origin/$BranchPrefix*'"
        return $null
    }

    # Strip "origin/" prefix and whitespace
    $names = @($remoteBranches | ForEach-Object { ($_.Trim() -replace '^origin/', '') })

    # Keep only YYMM-clean branches: must end in exactly 4 digits (no suffix like _hotfix _az _rollback)
    # Pattern: <prefix><YYMM>  (e.g. releases/prot2607)
    $escapedPrefix = [regex]::Escape($BranchPrefix)
    $clean = $names | Where-Object { $_ -match "^${escapedPrefix}(\d{4})$" }

    if (-not $clean) {
        Write-Warning "Get-PreviousBranch: no YYMM-clean branches found under '$BranchPrefix'"
        return $null
    }

    # Sort ascending and exclude current month
    $sorted = @($clean | Sort-Object)
    $previous = $sorted | Where-Object { $_ -notmatch $CurrentYYMM } | Select-Object -Last 1

    if (-not $previous) {
        # Fallback: return the most recent regardless of month exclusion
        $previous = $sorted | Select-Object -Last 1
        Write-Warning "Get-PreviousBranch: all branches match current YYMM; returning most recent: $previous"
    }

    return $previous
}
finally {
    Pop-Location
}
