<#
.SYNOPSIS
    Classifies every region/stamp that is NOT in the rollout, so release comms can
    state the true shape of a production rollout instead of just its size.

.DESCRIPTION
    The trigger notification historically said "{N} pipelines running" and nothing
    about scope. prot2608 shipped at 66 of 73 geographies and nobody noticed, because
    nothing ever stated the scope out loud.

    A flat "excluded regions" list would be actively harmful: it would mix deliberate
    exclusions with accidental omissions, and readers would learn to skim past the
    whole block — the same way the L-09 / L-16 warnings were skimmed past under release
    pressure. So this classifies exclusions into two buckets with opposite meanings:

      DELIBERATE (informational — the rollout is correct):
        - ccoa      : CCOA-excluded stamps (service-config inventory.ccoaExclusions)
        - r2dScope  : regions outside the SafeFly R2D approved scope
        - cloud     : stamps filtered out because they belong to another cloud (L-04)

      UNINTENDED (alarming — the rollout may be wrong):
        - missingGeography : geographies no pipeline covers (L-16) — the 66-of-73 class
        - inventoryDrift   : stamps the inventory could NOT validate, which therefore
                             vanished from the rollout without anyone being told

    This REPORTS. It never authorises. The L-16 gate in Assert-GeographyCoverage.ps1
    still blocks on missing > 0 and must keep blocking — a "we mentioned it in the
    email" culture is precisely how these defects shipped in the first place.

.PARAMETER ReleaseId
    Release whose state holds the geographyCoverage report.

.PARAMETER Coverage
    Pre-loaded geographyCoverage object (bypasses state loading).

.PARAMETER ServiceConfig
    Parsed service-config.json, for inventory.ccoaExclusions.

.PARAMETER InventoryDrift
    Drift rows from Get-StampInventory / Approve-Inventory (readiness.json →
    inventory.drift). Each row is expected to carry stampName and reason.

.PARAMETER ApprovedRegions
    Regions the SafeFly R2D approved. Regions present here but absent from the
    rollout are reported as r2dScope exclusions.

.OUTPUTS
    PSCustomObject with deliberate[], unintended[], counts, and hasUnintended.
#>
function Get-RolloutScopeReport {
    [CmdletBinding()]
    param(
        [string] $ReleaseId,
        [PSCustomObject] $Coverage,
        [PSCustomObject] $ServiceConfig,
        [object[]] $InventoryDrift,
        [string[]] $ApprovedRegions,
        [string] $StateRoot
    )

    if (-not $Coverage -and $ReleaseId) {
        if (-not $StateRoot) { $StateRoot = Join-Path (Get-Location) '.zed-agent/releases' }
        $stateFile = Join-Path $StateRoot "$ReleaseId/release.json"
        if (Test-Path $stateFile) {
            try {
                $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($state.PSObject.Properties['geographyCoverage']) { $Coverage = $state.geographyCoverage }
            } catch {
                Write-Warning "Get-RolloutScopeReport: could not read release state for '$ReleaseId': $_"
            }
        }
    }

    $deliberate = @()
    $unintended = @()

    # ── Deliberate: CCOA exclusions ──
    if ($ServiceConfig -and $ServiceConfig.PSObject.Properties['inventory'] -and
        $ServiceConfig.inventory -and $ServiceConfig.inventory.PSObject.Properties['ccoaExclusions'] -and
        $ServiceConfig.inventory.ccoaExclusions) {
        $excl = $ServiceConfig.inventory.ccoaExclusions
        $stamps = @()
        if ($excl.PSObject.Properties['stamps']) { $stamps = @($excl.stamps) }
        foreach ($s in $stamps) {
            $name = if ($s -is [string]) { $s } elseif ($s.PSObject.Properties['stampId']) { $s.stampId } else { [string]$s }
            $reason = if ($s -isnot [string] -and $s.PSObject.Properties['reason'] -and $s.reason) { $s.reason } else { 'CCOA exclusion' }
            $deliberate += [PSCustomObject]@{ kind = 'ccoa'; item = [string]$name; reason = [string]$reason }
        }
    }

    # ── Deliberate: approved by SafeFly but not in the covered set ──
    # NOTE: this is the reporting half of the R9 finding. The GATE — refusing to
    # deploy to regions SafeFly never approved — is a separate, still-open defect.
    if ($ApprovedRegions -and $Coverage) {
        $coveredRegions = @()
        if ($Coverage.PSObject.Properties['perPipeline'] -and $Coverage.perPipeline) {
            foreach ($p in $Coverage.perPipeline.PSObject.Properties) {
                $coveredRegions += @($p.Value.regions)
            }
        }
        $coveredLookup = @{}
        foreach ($r in $coveredRegions) { if ($r) { $coveredLookup[([string]$r).ToLower()] = $true } }
        foreach ($r in $ApprovedRegions) {
            if ($r -and -not $coveredLookup.ContainsKey(([string]$r).ToLower())) {
                $deliberate += [PSCustomObject]@{
                    kind   = 'r2dScope'
                    item   = [string]$r
                    reason = 'Approved in SafeFly R2D but not in this rollout'
                }
            }
        }
    }

    # ── Unintended: geographies no pipeline covers (L-16) ──
    if ($Coverage -and $Coverage.PSObject.Properties['missingGeographies']) {
        foreach ($g in @($Coverage.missingGeographies)) {
            if ($g) {
                $unintended += [PSCustomObject]@{
                    kind   = 'missingGeography'
                    item   = [string]$g
                    reason = 'No pipeline covers this geography — rollout would be incomplete'
                }
            }
        }
    }

    # ── Unintended: stamps the inventory could not validate ──
    foreach ($d in @($InventoryDrift)) {
        if (-not $d) { continue }
        $name = if ($d -is [string]) { $d } elseif ($d.PSObject.Properties['stampName']) { $d.stampName } else { [string]$d }
        $reason = if ($d -isnot [string] -and $d.PSObject.Properties['reason'] -and $d.reason) { $d.reason } else { 'Inventory could not validate this stamp' }
        $unintended += [PSCustomObject]@{ kind = 'inventoryDrift'; item = [string]$name; reason = [string]$reason }
    }

    return [PSCustomObject]@{
        deliberate      = @($deliberate)
        unintended      = @($unintended)
        deliberateCount = @($deliberate).Count
        unintendedCount = @($unintended).Count
        hasUnintended   = (@($unintended).Count -gt 0)
        computedAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
}

<#
.SYNOPSIS
    Renders a Get-RolloutScopeReport result as the HTML scope note used by release comms.

.DESCRIPTION
    Deliberate exclusions render as a plain informational list. Unintended omissions
    render first, under a loud heading, so the two can never be confused at a glance.
    Both the email (Step 15 action 4) and the Teams path render through this one
    function so the two channels cannot drift apart.
#>
function Format-RolloutScopeNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Report
    )

    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $html = ''

    if (@($Report.unintended).Count -gt 0) {
        $rows = @()
        foreach ($u in $Report.unintended) {
            $rows += "<tr><td><b>$(& $enc $u.item)</b></td><td>$(& $enc $u.kind)</td><td>$(& $enc $u.reason)</td></tr>"
        }
        $html += "<b>🔴 NOT deployed — unintended ($(@($Report.unintended).Count)):</b><br>" +
                 "<table>$($rows -join '')</table>" +
                 "<i>These were not deliberately excluded. Verify before allowing the rollout to continue.</i><br><br>"
    }

    if (@($Report.deliberate).Count -gt 0) {
        $rows = @()
        foreach ($d in $Report.deliberate) {
            $rows += "<tr><td>$(& $enc $d.item)</td><td>$(& $enc $d.kind)</td><td>$(& $enc $d.reason)</td></tr>"
        }
        $html += "<b>ℹ️ Deliberately excluded ($(@($Report.deliberate).Count)):</b><br>" +
                 "<table>$($rows -join '')</table>"
    }

    if ([string]::IsNullOrEmpty($html)) {
        $html = '<i>No regions or stamps were excluded from this rollout.</i>'
    }

    return $html
}
