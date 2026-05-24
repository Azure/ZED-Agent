<#
.SYNOPSIS
    Records an inventory approval decision into .zed-agent/readiness.json
    so that Test-InventoryGate.ps1 (and via it Step 10 / Step 15 of the
    run loop) will permit production-mutating operations.

.DESCRIPTION
    Usage pattern:
      1. Run Get-StampInventory.ps1 -Scope production -PipelineKey <key>
         (optionally per cloud). Capture its output to disk or stdin.
      2. Review the drift[] and sdsReconciliation blocks.
      3. Run this script to persist approval. The agent prompts for owner
         identity (defaulting to env:USERNAME@microsoft.com); supply
         -ApprovedBy explicitly when running non-interactively.

    The script is intentionally additive \u2014 it never re-runs the inventory.
    It only consumes the result the owner is approving.

.PARAMETER InventoryPath
    Path to a JSON file holding the Get-StampInventory.ps1 result. Mutually
    exclusive with -InventoryObject.

.PARAMETER InventoryObject
    A Get-StampInventory.ps1 result object passed directly from PowerShell.
    Mutually exclusive with -InventoryPath.

.PARAMETER ApprovedBy
    Email/UPN of the approver. Defaults to "$env:USERNAME@microsoft.com".

.PARAMETER Override
    Set readiness.inventory.overridden=true. Required when the inventory's
    status is 'drift' \u2014 documents that the owner accepted the drift.

.PARAMETER ReadinessPath
    Override the default location (.zed-agent/readiness.json in cwd).

.OUTPUTS
    PSCustomObject mirroring the persisted readiness.inventory section.
#>
[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Path')][string]$InventoryPath,
    [Parameter(Mandatory=$true, ParameterSetName='Object')][object]$InventoryObject,
    [string]$ApprovedBy,
    [switch]$Override,
    [string]$ReadinessPath
)

$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    if (-not (Test-Path $InventoryPath)) { throw "Inventory file not found: $InventoryPath" }
    $inv = Get-Content $InventoryPath -Raw | ConvertFrom-Json
} else {
    $inv = $InventoryObject
}

if (-not $ApprovedBy) {
    $user = $env:USERNAME
    if ($user) { $ApprovedBy = "$user@microsoft.com" } else { throw "Could not infer approver; pass -ApprovedBy explicitly." }
}

# Derive status from the inventory snapshot.
$status = 'pass'
$drift  = @()
if ($inv.drift) { $drift = @($inv.drift) }
if ($inv.sdsReconciliation -and -not $inv.sdsReconciliation.withinTolerance) {
    $status = 'drift'
} elseif (@($drift | Where-Object { $_.side -in @('sdsOnly','kustoOnly') }).Count -gt 0 -and -not $inv.sdsReconciliation.withinTolerance) {
    $status = 'drift'
}

if ($status -eq 'drift' -and -not $Override) {
    throw "Inventory has unresolved drift (driftCount=$($inv.sdsReconciliation.driftCount), tolerance=$($inv.sdsReconciliation.toleranceCount)). Re-run with -Override to record explicit acceptance, or fix the drift and re-run Get-StampInventory.ps1."
}

$sdsBlock = $null
if ($inv.sdsReconciliation) {
    $sdsBlock = @{
        hash       = $inv.sdsReconciliation.hash
        source     = $inv.sdsReconciliation.source
        stampCount = $inv.sdsReconciliation.stampCount
    }
}

$kustoBlock = $null
if ($inv.kusto) {
    $kustoBlock = @{
        ranAt      = $inv.kusto.ranAt
        rowCount   = $inv.kusto.rowCount
        stampCount = @($inv.stamps).Count
    }
}

$data = @{
    ranAt       = (Get-Date).ToUniversalTime().ToString('o')
    status      = $status
    pipelineKey = $inv.pipelineKey
    cloud       = $inv.cloud
    stampCount  = @($inv.stamps).Count
    sds         = $sdsBlock
    kusto       = $kustoBlock
    drift       = @($drift)
    approved    = $true
    approvedAt  = (Get-Date).ToUniversalTime().ToString('o')
    approvedBy  = $ApprovedBy
    overridden  = [bool]$Override
}

$writer = Join-Path $PSScriptRoot 'Write-Readiness.ps1'
$writeArgs = @{ Stage = 'inventory'; Data = $data }
if ($ReadinessPath) { $writeArgs.ReadinessPath = $ReadinessPath }
& $writer @writeArgs | Out-Null

return [PSCustomObject]$data
