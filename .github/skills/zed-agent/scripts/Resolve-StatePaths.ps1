<#
.SYNOPSIS
    Resolves durable (git-committed) and scratch (gitignored) state paths for a ZED release.

.DESCRIPTION
    ZED persists two categories of data:
      - DURABLE: release record (release.json, state.json, audit.jsonl, audit.md) that
        must survive across sessions. In local mode these live under .zed-agent/; in cloud
        mode they are committed to .zed-release/ on the release branch.
      - SCRATCH: secrets, locks, caches, readiness — always gitignored under .zed-agent/.

    This script returns both paths so callers can locate state regardless of execution mode.

    The durable path is determined by checking for the existence of .zed-release/ first (cloud
    mode / committed state), then falling back to .zed-agent/ (local devbox mode). This
    ensures local behavior is unchanged while cloud sessions find committed state.

.PARAMETER ReleaseId
    The release identifier (e.g., '2026-04').

.PARAMETER RepoRoot
    Optional repo root. Defaults to current directory.

.PARAMETER PreferDurable
    When set, creates .zed-release/ path structure if it doesn't exist.

.OUTPUTS
    PSCustomObject with properties:
      DurableBase   - Base dir for durable state (.zed-release/ or .zed-agent/)
      DurableDir    - Full path: DurableBase/releases/{id}
      ScratchBase   - Base dir for scratch data (.zed-agent/)
      ScratchDir    - Full path: ScratchBase/releases/{id}
      StateFile     - DurableDir/state.json
      ReleaseFile   - DurableDir/release.json
      AuditFile     - DurableDir/audit.jsonl
      AuditMdFile   - DurableDir/audit.md
      SecretsFile   - ScratchDir/secrets.json (NEVER committed)
      LockFile      - ScratchDir/state.json.lock
      WatcherLock   - ScratchDir/watcher.lock
      IsDurableMode - $true if using .zed-release/ (cloud/committed mode)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$RepoRoot,
    [switch]$PreferDurable
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Get-Location }

$durableBase  = Join-Path $RepoRoot '.zed-release'
$scratchBase  = Join-Path $RepoRoot '.zed-agent'
$isDurableMode = $false

# Determine if we're in durable mode:
# 1. If .zed-release/ exists with releases/{id}/ → durable mode
# 2. If -PreferDurable is set → create .zed-release/ structure
# 3. Otherwise → fall back to .zed-agent/ (local compatibility)
$durableReleaseDir = Join-Path $durableBase "releases/$ReleaseId"
$scratchReleaseDir = Join-Path $scratchBase "releases/$ReleaseId"

if (Test-Path (Join-Path $durableReleaseDir 'state.json')) {
    $isDurableMode = $true
} elseif (Test-Path (Join-Path $durableReleaseDir 'release.json')) {
    $isDurableMode = $true
} elseif ($PreferDurable) {
    $isDurableMode = $true
    if (-not (Test-Path $durableReleaseDir)) {
        New-Item -ItemType Directory -Path $durableReleaseDir -Force | Out-Null
    }
}

$effectiveBase = if ($isDurableMode) { $durableBase } else { $scratchBase }
$effectiveDir  = if ($isDurableMode) { $durableReleaseDir } else { $scratchReleaseDir }

[PSCustomObject]@{
    DurableBase   = $durableBase
    DurableDir    = $durableReleaseDir
    ScratchBase   = $scratchBase
    ScratchDir    = $scratchReleaseDir
    StateFile     = Join-Path $effectiveDir 'state.json'
    ReleaseFile   = Join-Path $effectiveDir 'release.json'
    AuditFile     = Join-Path $effectiveDir 'audit.jsonl'
    AuditMdFile   = Join-Path $effectiveDir 'audit.md'
    SecretsFile   = Join-Path $scratchReleaseDir 'secrets.json'
    LockFile      = Join-Path $scratchReleaseDir 'state.json.lock'
    WatcherLock   = Join-Path $scratchReleaseDir 'watcher.lock'
    IsDurableMode = $isDurableMode
}
