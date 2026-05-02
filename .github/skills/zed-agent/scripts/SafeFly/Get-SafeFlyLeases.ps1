<#
.SYNOPSIS
    Queries active SafeFly leases for the configured service.

.DESCRIPTION
    Calls the SafeFly Lease API to retrieve all active approved leases for the
    configured service tree ID. Useful for pre-flight checks and understanding
    auto-approval coverage.

.PARAMETER ServiceTreeId
    Service tree GUID. Default: loaded from service config.

.OUTPUTS
    Array of lease objects with id, title, leaseType, state, regexForTitleMatching.

.EXAMPLE
    $leases = .\Get-SafeFlyLeases.ps1
    $leases | Where-Object state -eq "Approved" | Format-Table title, leaseType
#>
[CmdletBinding()]
param(
    [string] $ServiceTreeId,

    [Parameter()]
    [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\..\service-config.json')
)

$ErrorActionPreference = "Stop"

# --- Load service config ---
$cfg = & (Join-Path $PSScriptRoot '..\..\Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

if (-not $ServiceTreeId) {
    $ServiceTreeId = $cfg.serviceTreeIds.safefly
}

$SafeFlyEndpoint   = "https://www.safefly.azure.com"
$SafeFlyResourceId = "api://6bca76ac-6a99-4b70-bb47-23ae8bc1f0f6"

# --- Authenticate ---
$token = az account get-access-token --resource $SafeFlyResourceId --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire SafeFly API token." }

$headers = @{ Authorization = "Bearer $token" }

# --- Query leases ---
$uri = "$SafeFlyEndpoint/api/SafeFlyLease/v1/lease/$ServiceTreeId"

try {
    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    throw "SafeFly lease API returned HTTP $statusCode"
}

$leases = @($response)
$approved = @($leases | Where-Object { $_.state -eq "Approved" })

Write-Host "Found $($leases.Count) lease(s), $($approved.Count) approved" -ForegroundColor Cyan

foreach ($lease in $approved) {
    Write-Host "  • $($lease.title) ($($lease.leaseType)) — regex: $($lease.regexForTitleMatching)" -ForegroundColor Gray
}

return $leases
