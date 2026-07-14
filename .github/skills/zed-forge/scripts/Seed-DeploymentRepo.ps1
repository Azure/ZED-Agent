<#
.SYNOPSIS
    Prepare the target deployment repo for a validation run: install the LATEST
    ZED (with this iteration's fixes) then overlay ZedForge's kept config files.

.DESCRIPTION
    On every iteration ZedForge (1) copies the current ZED agent + skill into the
    target repo via Install-Zed.ps1 -Force (so the validation run exercises the
    just-modified ZED), then (2) overlays the pre-filled files listed in
    config-seed/manifest.json (service-config.json + pipeline-catalog.json, and
    anything else the manifest carries). Install-Zed writes EMPTY configs, so the
    overlay MUST run after it.

.PARAMETER TargetRepo   Target deployment repo. Default from manifest.targetRepoDefault.
.PARAMETER SourceRepo   ZED-Agent repo root (where zed-forge lives). Auto-detected.
.PARAMETER ManifestPath Override. Default <skill>/config-seed/manifest.json.
.PARAMETER SkipInstall  Skip the Install-Zed step (only overlay configs).
#>
[CmdletBinding()]
param(
    [string]$TargetRepo,
    [string]$SourceRepo,
    [string]$ManifestPath,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path $PSScriptRoot -Parent          # .../.github/skills/zed-forge
if (-not $SourceRepo) {
    $SourceRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path   # repo root
}
if (-not $ManifestPath) { $ManifestPath = Join-Path $skillRoot 'config-seed\manifest.json' }
if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }

$manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $TargetRepo) { $TargetRepo = $manifest.targetRepoDefault }
if (-not $TargetRepo) { throw "TargetRepo not supplied and manifest has no targetRepoDefault." }
if (-not (Test-Path $TargetRepo)) { throw "Target repo does not exist: $TargetRepo" }

$result = [ordered]@{
    targetRepo = $TargetRepo
    installed  = $false
    copied     = @()
    errors     = @()
}

# ── 1. Install the latest ZED into the target ──
if ($manifest.installZedFirst -and -not $SkipInstall) {
    $installer = Join-Path $SourceRepo '.github\skills\zed-agent\scripts\Install-Zed.ps1'
    if (-not (Test-Path $installer)) { throw "Install-Zed.ps1 not found: $installer" }
    Write-Host "Installing latest ZED into $TargetRepo ..."
    & $installer -TargetRepoPath $TargetRepo -Force | Out-Null
    $result.installed = $true
}

# ── 2. Overlay kept config files ──
foreach ($f in $manifest.files) {
    $src = Join-Path $skillRoot ($f.from -replace '/', '\')
    $dst = Join-Path $TargetRepo ($f.to -replace '/', '\')
    if (-not (Test-Path $src)) { $result.errors += "missing source: $src"; continue }
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item $src $dst -Force
    $result.copied += $f.to
    Write-Host "  overlaid $($f.to)"
}

if ($result.errors.Count) { Write-Warning ("Seed completed with errors: " + ($result.errors -join '; ')) }
return [pscustomobject]$result
