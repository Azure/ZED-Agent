<#
.SYNOPSIS
    Reads .zed-agent/readiness.json → inventory and decides whether
    Step 10 (Roll-Forward) and Step 15 (Production Rollout) are allowed
    to fire. Pure side-effect-free gate \u2014 it never mutates readiness.

.DESCRIPTION
    Called by the run loop before any production-mutating step (and by
    setup before persisting setup.status=pass when inventory.production
    .approvalRequired=true). Returns a structured verdict; the caller
    decides whether to halt the release or prompt the owner to re-run
    Approve-Inventory.ps1.

    Verdict rules (in order, first match wins):
      - skip      : service-config.json → inventory.production.approvalRequired
                    is false. Caller may proceed.
      - missing   : readiness.inventory does not exist. Caller must run
                    Get-StampInventory.ps1 + Approve-Inventory.ps1 first.
      - notApproved : readiness.inventory.approved != true. Owner must
                    review and approve via Approve-Inventory.ps1.
      - hashDrift : readiness.inventory.sds.hash differs from the SDS
                    parsed RIGHT NOW. SDS has changed since approval \u2014
                    re-run inventory + re-approve.
      - driftExceeded : readiness.inventory.status == 'drift' AND
                    .overridden != true. Owner must re-approve with
                    -Override or fix the drift.
      - stale     : readiness.inventory.ranAt is older than -MaxAgeHours
                    (default 72). Caller should refresh.
      - pass      : everything green.

    The hashDrift check requires the same SDS configuration the approved
    snapshot used. When -PipelineKey is omitted, the helper reads
    readiness.inventory.pipelineKey.

.PARAMETER PipelineKey
    Which sds.<key> to validate against. Defaults to readiness.inventory.pipelineKey.

.PARAMETER MaxAgeHours
    Staleness threshold. Default 72.

.PARAMETER SkipHashCheck
    Skip the live SDS re-parse hash compare. Used when the caller has
    already validated the SDS hash this session (e.g. inside a single
    'run' invocation that already called Get-StampInventory.ps1).

.OUTPUTS
    PSCustomObject:
      verdict       : 'pass' | 'skip' | 'missing' | 'notApproved' | 'hashDrift' | 'driftExceeded' | 'stale'
      reason        : human-readable explanation
      pipelineKey   : the key validated
      readiness     : the readiness.inventory record (or $null)
      hashLive      : SHA-256 of the SDS as it exists right now (when checked)
      hashApproved  : SHA-256 stored in readiness when approved
#>
[CmdletBinding()]
param(
    [string]$ServiceConfigPath,
    [string]$ReadinessPath,
    [string]$PipelineKey,
    [int]   $MaxAgeHours = 72,
    [switch]$SkipHashCheck
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\')).Path
if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $repoRoot '.github\skills\zed-agent\service-config.json' }
if (-not $ReadinessPath)     { $ReadinessPath     = Join-Path (Get-Location) '.zed-agent\readiness.json' }

if (-not (Test-Path $ServiceConfigPath)) { throw "service-config.json not found at $ServiceConfigPath." }
$config = Get-Content $ServiceConfigPath -Raw | ConvertFrom-Json

$approvalRequired = $true
if ($config.inventory -and $config.inventory.production -and $null -ne $config.inventory.production.approvalRequired) {
    $approvalRequired = [bool]$config.inventory.production.approvalRequired
}

function New-Verdict {
    param([string]$Verdict, [string]$Reason, $Readiness, [string]$Key, [string]$HashLive, [string]$HashApproved)
    [PSCustomObject]@{
        verdict      = $Verdict
        reason       = $Reason
        pipelineKey  = $Key
        readiness    = $Readiness
        hashLive     = $HashLive
        hashApproved = $HashApproved
    }
}

if (-not $approvalRequired) {
    return (New-Verdict 'skip' 'service-config.json -> inventory.production.approvalRequired is false' $null $PipelineKey $null $null)
}

if (-not (Test-Path $ReadinessPath)) {
    return (New-Verdict 'missing' "readiness.json not found at $ReadinessPath" $null $PipelineKey $null $null)
}
$readiness = Get-Content $ReadinessPath -Raw | ConvertFrom-Json
if (-not $readiness.inventory) {
    return (New-Verdict 'missing' 'readiness.inventory has not been recorded' $null $PipelineKey $null $null)
}
$inv = $readiness.inventory

if (-not $PipelineKey) { $PipelineKey = $inv.pipelineKey }

if (-not $inv.approved) {
    return (New-Verdict 'notApproved' 'readiness.inventory.approved is not true' $inv $PipelineKey $null $inv.sds.hash)
}
if ($inv.status -eq 'drift' -and -not $inv.overridden) {
    return (New-Verdict 'driftExceeded' 'readiness.inventory.status is drift and not explicitly overridden' $inv $PipelineKey $null $inv.sds.hash)
}

# Staleness
try {
    $ranAt = [datetime]::Parse($inv.ranAt).ToUniversalTime()
    $ageHrs = ((Get-Date).ToUniversalTime() - $ranAt).TotalHours
    if ($ageHrs -gt $MaxAgeHours) {
        return (New-Verdict 'stale' ("readiness.inventory.ranAt is {0:N1}h old (max {1}h)" -f $ageHrs, $MaxAgeHours) $inv $PipelineKey $null $inv.sds.hash)
    }
} catch {
    return (New-Verdict 'stale' "readiness.inventory.ranAt is not a parseable timestamp: $($inv.ranAt)" $inv $PipelineKey $null $inv.sds.hash)
}

# Hash drift: re-parse SDS now and compare. Only when the approved record has
# a hash to compare against (sovereign + Public-reconciled flows both record one).
if (-not $SkipHashCheck -and $inv.sds -and $inv.sds.hash -and $PipelineKey) {
    if (-not $config.sds -or -not $config.sds.PSObject.Properties[$PipelineKey]) {
        return (New-Verdict 'hashDrift' "service-config.json -> sds.$PipelineKey is missing but readiness records a hash" $inv $PipelineKey $null $inv.sds.hash)
    }
    $sdsEntry = $config.sds.$PipelineKey
    $sdsPath = if ($sdsEntry.localClonePath) { Join-Path $sdsEntry.localClonePath $sdsEntry.path } else { $sdsEntry.path }
    if (-not (Test-Path $sdsPath)) {
        return (New-Verdict 'hashDrift' "SDS file not available at '$sdsPath' for re-hash" $inv $PipelineKey $null $inv.sds.hash)
    }
    $sdsScript = Join-Path $PSScriptRoot 'Get-StampInventoryFromSds.ps1'
    # The SDS hash is CLOUD-SCOPED: Get-StampInventoryFromSds returns a different
    # hash for -Cloud Public than for no -Cloud. The writer (Get-StampInventory)
    # records the hash for the inventory's cloud, so the gate MUST rehash under the
    # same cloud or every Public inventory reports a permanent, unfixable hashDrift.
    $sdsArgs = @{ SdsPath = $sdsPath; ServiceConfigPath = $ServiceConfigPath }
    $hashCloud = if ($inv.sds.cloud) { $inv.sds.cloud } elseif ($inv.cloud) { $inv.cloud } else { $null }
    if ($hashCloud) { $sdsArgs['Cloud'] = $hashCloud }
    $live = & $sdsScript @sdsArgs
    if ($live.hash -ne $inv.sds.hash) {
        return (New-Verdict 'hashDrift' "SDS hash changed since approval (was $($inv.sds.hash.Substring(0,12))..., now $($live.hash.Substring(0,12))...)" $inv $PipelineKey $live.hash $inv.sds.hash)
    }
    return (New-Verdict 'pass' 'inventory approved and SDS hash matches' $inv $PipelineKey $live.hash $inv.sds.hash)
}

return (New-Verdict 'pass' 'inventory approved (hash check skipped)' $inv $PipelineKey $null $inv.sds.hash)
