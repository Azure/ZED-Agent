<#
.SYNOPSIS
    Pre-flight connectivity test for the SafeFly API.

.DESCRIPTION
    Validates that the current user can authenticate to SafeFly and query
    the lease API. Used during setup step 9 to verify access before the
    release pipeline starts.

.OUTPUTS
    PSCustomObject with: connected (bool), leaseCount, approvedLeaseCount, error.

.EXAMPLE
    $check = .\Test-SafeFlyConnection.ps1
    if ($check.connected) { Write-Host "✅ SafeFly OK" }
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"

# --- Load service config ---
$cfg = & (Join-Path $PSScriptRoot '..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

$SafeFlyResourceId = "api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6"
$ServiceTreeId     = $cfg.serviceTreeIds.safefly

$result = [PSCustomObject]@{
    connected          = $false
    leaseCount         = 0
    approvedLeaseCount = 0
    error              = $null
}

try {
    # Test token acquisition
    Write-Host "Testing SafeFly authentication..." -ForegroundColor Gray
    $token = az account get-access-token --resource $SafeFlyResourceId --query accessToken -o tsv
    if (-not $token) { throw "Token acquisition returned empty." }

    # Test API call via lease endpoint
    Write-Host "Testing SafeFly API connectivity..." -ForegroundColor Gray
    $leases = & "$PSScriptRoot\Get-SafeFlyLeases.ps1" -ServiceTreeId $ServiceTreeId

    $result.connected          = $true
    $result.leaseCount         = @($leases).Count
    $result.approvedLeaseCount = @($leases | Where-Object { $_.state -eq "Approved" }).Count

    Write-Host "✅ SafeFly API connected — $($result.approvedLeaseCount) approved lease(s)" -ForegroundColor Green
}
catch {
    $result.error = $_.Exception.Message
    Write-Host "❌ SafeFly connection failed: $($result.error)" -ForegroundColor Red
}

return $result
