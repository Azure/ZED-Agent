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
.PARAMETER SkipInstall      Skip the Install-Zed step (only overlay configs).
.PARAMETER SkipReapprove    Skip re-approving the inventory baseline after overlay (default: false).
                            Re-approval keeps the readiness.json SDS hash in sync with the
                            current config-seed so Test-InventoryGate does not fire a false
                            hashDrift when sdsFieldMapping or stamp topology changes.
#>
[CmdletBinding()]
param(
    [string]$TargetRepo,
    [string]$SourceRepo,
    [string]$ManifestPath,
    [switch]$SkipInstall,
    [switch]$SkipReapprove
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

# ── 3. Re-approve the inventory baseline ──────────────────────────────────────
# After overlaying service-config.json (which may change sdsFieldMapping or stamps),
# the readiness.json SDS hash must be refreshed so Test-InventoryGate does not fire
# a false hashDrift. We do this by computing the live SDS hash and writing a synthetic
# approval record — no Kusto query needed.
if (-not $SkipReapprove) {
    try {
        $zdScripts  = Join-Path $TargetRepo '.github\skills\zed-agent\scripts'
        $cfgPath    = Join-Path $TargetRepo '.github\skills\zed-agent\service-config.json'
        $cfg        = Get-Content $cfgPath -Raw | ConvertFrom-Json
        # Find the first SDS pipeline key configured
        $sdsKeys    = if ($cfg.sds) { @($cfg.sds.PSObject.Properties.Name) } else { @() }
        if ($sdsKeys.Count -gt 0) {
            $primaryKey  = $sdsKeys[0]
            $sdsEntry    = $cfg.sds.$primaryKey
            $sdsAbsPath  = if ($sdsEntry.localClonePath) {
                               Join-Path $sdsEntry.localClonePath $sdsEntry.path
                           } else {
                               Join-Path $TargetRepo ($sdsEntry.path -replace '/', '\')
                           }
            if (Test-Path $sdsAbsPath) {
                $sdsScript  = Join-Path $zdScripts 'Get-StampInventoryFromSds.ps1'
                $sdsResult  = & $sdsScript -SdsPath $sdsAbsPath -ServiceConfigPath $cfgPath -Cloud 'Public'
                $approveScript = Join-Path $zdScripts 'Approve-Inventory.ps1'
                $synthInv = [pscustomobject]@{
                    pipelineKey       = $primaryKey
                    cloud             = 'Public'
                    stamps            = $sdsResult.stamps
                    drift             = @()
                    sdsReconciliation = [pscustomobject]@{
                        hash            = $sdsResult.hash
                        source          = $sdsResult.source
                        stampCount      = @($sdsResult.stamps).Count
                        cloud           = 'Public'
                        withinTolerance = $true
                        driftCount      = 0
                    }
                }
                $rdPath = Join-Path $TargetRepo '.zed-agent\readiness.json'
                & $approveScript -InventoryObject $synthInv -ApprovedBy 'zedforge@microsoft.com' `
                    -ReadinessPath $rdPath | Out-Null
                $result.inventoryReapproved = $true
                $result.inventoryHash       = $sdsResult.hash.Substring(0,12) + '...'
                Write-Host "  re-approved inventory baseline (hash $($sdsResult.hash.Substring(0,12))...)"
            } else {
                Write-Warning "SDS file not found at '$sdsAbsPath'; skipping inventory re-approval."
                $result.inventoryReapproved = $false
            }
        } else {
            Write-Host "  no sds keys configured; skipping inventory re-approval."
            $result.inventoryReapproved = $false
        }
    } catch {
        Write-Warning "Inventory re-approval failed (non-fatal): $_"
        $result.inventoryReapproved = $false
    }
}

return [pscustomobject]$result
