# Repair-AzAuth.ps1
#
# Standalone auth-remediation cascade used by Test-PreFlight.ps1 AND by any
# in-flight ZED Agent step that hits an `az` / Kusto token failure mid-run.
#
# Cascade (each attempt re-tests the actual token, not just `az account show`):
#   1. az account clear; az login --tenant <Tenant>   (interactive browser, WAM may still be on)
#   2. az config set core.enable_broker_on_windows=false; clear; login again
#      (canonical fix for the WAM-can't-issue-tokens-for-custom-resources bug)
#   3. az login --tenant <Tenant> --use-device-code   (last resort; some tenants block this via CA)
#
# Returns: PSCustomObject with .ok (bool), .user (UPN), .loginExit (int), .lastError (string|null)
#
# Usage from a script / agent step:
#   $r = & "$skillsRoot/scripts/Repair-AzAuth.ps1" -Tenant 'microsoft.com' -Resource 'https://mabprod1.kusto.windows.net'
#   if (-not $r.ok) { throw "az auth could not be remediated: $($r.lastError)" }
[CmdletBinding()]
param(
    [string]$Tenant = 'microsoft.com',
    # Optional: when provided, the cascade validates `az account get-access-token --resource <Resource>`
    # at each step. Use the actual Kusto cluster URL (matches token audience) rather than the
    # generic https://kusto.kusto.windows.net which produces tokens real clusters reject.
    [string]$Resource
)

$ErrorActionPreference = 'Stop'

function Test-AzToken {
    param([string]$Resource)
    if ($Resource) {
        $p = az account get-access-token --resource $Resource --query expiresOn -o tsv 2>&1
    } else {
        $p = az account get-access-token --query expiresOn -o tsv 2>&1
    }
    return @{ ok = ($LASTEXITCODE -eq 0 -and $p); detail = ($p | Out-String).Trim() }
}

$tokenOk   = $false
$lastErr   = $null
$loginExit = -1
$whoami    = $null

# ── Attempt 1: interactive browser login with current az config ──
Write-Host "[Repair-AzAuth] Attempt 1/3: az login --tenant $Tenant (interactive browser)." -ForegroundColor Yellow
az account clear 2>&1 | Out-Null
az login --tenant $Tenant | Out-Host
$loginExit = $LASTEXITCODE
$whoami    = az account show --query user.name -o tsv 2>$null
if ($loginExit -eq 0 -and $whoami) {
    $r = Test-AzToken -Resource $Resource
    $tokenOk = $r.ok; $lastErr = if ($r.ok) { $null } else { $r.detail }
}

# ── Attempt 2: disable the WAM broker and retry ──
# WAM has a known limitation: it can't acquire tokens for some custom resources
# (e.g., Kusto clusters). Disabling it is the documented fix, not a workaround.
if (-not $tokenOk) {
    Write-Host "[Repair-AzAuth] Attempt 2/3: disabling WAM broker (core.enable_broker_on_windows=false) and retrying." -ForegroundColor Yellow
    az config set core.enable_broker_on_windows=false 2>&1 | Out-Host
    az account clear 2>&1 | Out-Null
    az login --tenant $Tenant | Out-Host
    $loginExit = $LASTEXITCODE
    $whoami    = az account show --query user.name -o tsv 2>$null
    if ($loginExit -eq 0 -and $whoami) {
        $r = Test-AzToken -Resource $Resource
        $tokenOk = $r.ok; $lastErr = if ($r.ok) { $null } else { $r.detail }
    }
}

# ── Attempt 3: device code (last resort; CA may block this) ──
if (-not $tokenOk) {
    Write-Host "[Repair-AzAuth] Attempt 3/3: device-code flow. May be blocked by tenant Conditional Access." -ForegroundColor Yellow
    az login --tenant $Tenant --use-device-code | Out-Host
    $loginExit = $LASTEXITCODE
    $whoami    = az account show --query user.name -o tsv 2>$null
    if ($loginExit -eq 0 -and $whoami) {
        $r = Test-AzToken -Resource $Resource
        $tokenOk = $r.ok; $lastErr = if ($r.ok) { $null } else { $r.detail }
    }
}

[pscustomobject]@{
    ok        = $tokenOk
    user      = $whoami
    loginExit = $loginExit
    lastError = $lastErr
}
