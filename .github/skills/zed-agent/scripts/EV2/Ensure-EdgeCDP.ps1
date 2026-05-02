<#
.SYNOPSIS
    Ensures Edge is accessible via Chrome DevTools Protocol (CDP) on a given port.

.DESCRIPTION
    Checks if Edge CDP is already reachable. If not, launches Edge with
    --remote-debugging-port and polls until CDP responds.
    Also verifies that playwright-core npm package is installed.

.PARAMETER Port
    CDP port. Default: 9222.

.PARAMETER TimeoutSeconds
    Max wait for CDP to become reachable. Default: 15.

.OUTPUTS
    [bool] $true if CDP is ready; throws on failure.
#>
[CmdletBinding()]
param(
    [int] $Port = 9223,
    [int] $TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
$cdpUrl = "http://localhost:$Port"

# ── 1. Check if CDP is already reachable AND is the real Edge (not WebView2) ──
function Test-CdpReady {
    try {
        $version = Invoke-RestMethod -Uri "$cdpUrl/json/version" -TimeoutSec 3 -ErrorAction Stop
        # Verify this is actual Edge browser, not EdgeWebView2 (Teams hijacks port 9222)
        $browser = $version.Browser ?? $version.'User-Agent' ?? ''
        if ($browser -match 'WebView2') {
            Write-Warning "CDP on port $Port is EdgeWebView2 (not Edge browser). WebView2 has no MSAL tokens."
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

if (Test-CdpReady) {
    Write-Verbose "Edge CDP already reachable on port $Port."
} else {
    Write-Host "🔧 Starting Edge with CDP on port $Port..." -ForegroundColor Cyan

    # Find Edge executable
    $edgePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" -ErrorAction SilentlyContinue).'(default)'
    if (-not $edgePath -or -not (Test-Path $edgePath)) {
        $edgePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
    }
    if (-not (Test-Path $edgePath)) {
        throw "Microsoft Edge not found. Install Edge or set the path manually."
    }

    # Launch Edge with remote debugging — merges into existing Edge process
    Start-Process $edgePath -ArgumentList "--remote-debugging-port=$Port" -WindowStyle Minimized

    # Poll until CDP is ready
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-CdpReady) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }

    if (-not $ready) {
        throw "Edge CDP did not become reachable on port $Port within ${TimeoutSeconds}s. Ensure Edge is installed and no firewall blocks localhost:$Port."
    }
    Write-Host "✅ Edge CDP ready on port $Port." -ForegroundColor Green
}

# ── 2. Ensure playwright-core is available ──
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$nodeModulesDir = Join-Path $scriptDir "node_modules"
$pwCorePath = Join-Path $nodeModulesDir "playwright-core"

if (-not (Test-Path $pwCorePath)) {
    Write-Host "📦 Installing playwright-core..." -ForegroundColor Cyan
    Push-Location $scriptDir
    try {
        npm install --no-save playwright-core 2>&1 | Out-Null
        if (-not (Test-Path $pwCorePath)) {
            throw "npm install playwright-core failed. Ensure Node.js and npm are on PATH."
        }
        Write-Host "✅ playwright-core installed." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

return $true
