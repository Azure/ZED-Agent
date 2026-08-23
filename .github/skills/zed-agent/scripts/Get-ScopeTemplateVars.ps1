<#
.SYNOPSIS
    L-18: Supplies the route/geography scope tokens used by the release comms templates.

.DESCRIPTION
    WP-FGHI added {{routeCount}}, {{geographyCount}} and {{regionListHtml}} to the four
    release comms templates so every notification states WHICH geographies a rollout
    covers. Nothing populated them, and Expand-Template runs with -StrictPlaceholders
    ON by default, so any caller of those templates would have thrown
    "template has unsubstituted placeholders" at send time.

    This resolves the tokens from the geographyCoverage report that
    Assert-GeographyCoverage.ps1 (L-16) persists into release state at Step 15.

    Scope is reported, never guessed. When no coverage report exists yet the tokens
    resolve to an explicit "not yet computed" wording rather than a fabricated count —
    a comms message must never imply a scope that was not actually verified. This does
    not throw: blocking a release notification because scope metadata is missing would
    hide the rollout entirely, which is worse than an honest "not yet computed".

.PARAMETER ReleaseId
    Release whose state holds the geographyCoverage report.

.PARAMETER Coverage
    Pre-loaded coverage object. Bypasses state loading (used by tests and by callers
    that already hold the report).

.OUTPUTS
    Hashtable with routeCount, geographyCount, regionListHtml — merge into the
    -Variables hashtable passed to Expand-Template / Send-TeamsMessage.
#>
function Get-ScopeTemplateVars {
    [CmdletBinding()]
    param(
        [string] $ReleaseId,
        [PSCustomObject] $Coverage,
        [string] $StateRoot,
        # Optional inputs for the exclusion note. When supplied, {{exclusionNoteHtml}}
        # classifies deliberate exclusions vs unintended omissions.
        [PSCustomObject] $ServiceConfig,
        [object[]] $InventoryDrift,
        [string[]] $ApprovedRegions
    )

    if (-not $Coverage -and $ReleaseId) {
        if (-not $StateRoot) { $StateRoot = Join-Path (Get-Location) '.zed-agent/releases' }
        $stateFile = Join-Path $StateRoot "$ReleaseId/release.json"
        if (Test-Path $stateFile) {
            try {
                $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($state.PSObject.Properties['geographyCoverage']) {
                    $Coverage = $state.geographyCoverage
                }
            } catch {
                Write-Warning "Get-ScopeTemplateVars: could not read release state for '$ReleaseId': $_"
            }
        }
    }

    if (-not $Coverage) {
        return @{
            routeCount        = 'not yet computed'
            geographyCount    = 'not yet computed'
            regionListHtml    = '<i>Geography coverage has not been computed for this release yet.</i>'
            exclusionNoteHtml = '<i>Exclusion breakdown unavailable — geography coverage has not been computed yet.</i>'
        }
    }

    $geographies = @()
    if ($Coverage.PSObject.Properties['coveredGeographies']) {
        $geographies = @($Coverage.coveredGeographies)
    }

    # A "route" is one pipeline's slice of the rollout — SFRP and SFMC each carry a
    # distinct route through the geography set.
    $routeCount = 0
    if ($Coverage.PSObject.Properties['perPipeline'] -and $Coverage.perPipeline) {
        $routeCount = @($Coverage.perPipeline.PSObject.Properties).Count
    }

    $rows = @()
    if ($Coverage.PSObject.Properties['perPipeline'] -and $Coverage.perPipeline) {
        foreach ($p in $Coverage.perPipeline.PSObject.Properties) {
            $regions = @($p.Value.regions) -join ', '
            $safeKey = [System.Net.WebUtility]::HtmlEncode([string]$p.Name)
            $safeRegions = [System.Net.WebUtility]::HtmlEncode([string]$regions)
            $rows += "<tr><td><b>$safeKey</b></td><td>$safeRegions</td></tr>"
        }
    }

    $regionListHtml = if ($rows.Count -gt 0) {
        "<table>$($rows -join '')</table>"
    } else {
        '<i>No per-pipeline region breakdown available.</i>'
    }

    # L-16 left a loud trail when geographies are missing; comms must repeat it rather
    # than reporting a clean-looking partial scope.
    $missingCount = 0
    if ($Coverage.PSObject.Properties['missingCount']) { $missingCount = [int]$Coverage.missingCount }
    if ($missingCount -gt 0) {
        $missingList = ''
        if ($Coverage.PSObject.Properties['missingGeographies']) {
            $missingList = [System.Net.WebUtility]::HtmlEncode((@($Coverage.missingGeographies) -join ', '))
        }
        $regionListHtml += "<br><b>⚠️ $missingCount geograph(ies) NOT covered:</b> $missingList"
    }

    # L-18 / scope note: one shared renderer for BOTH the Step 15 email and the Teams
    # path, so the two channels can never state different scopes.
    . (Join-Path $PSScriptRoot 'Get-RolloutScopeReport.ps1')
    $scopeReport = Get-RolloutScopeReport -Coverage $Coverage -ServiceConfig $ServiceConfig `
        -InventoryDrift $InventoryDrift -ApprovedRegions $ApprovedRegions
    $exclusionNoteHtml = Format-RolloutScopeNote -Report $scopeReport

    return @{
        routeCount        = [string]$routeCount
        geographyCount    = [string]$geographies.Count
        regionListHtml    = $regionListHtml
        exclusionNoteHtml = $exclusionNoteHtml
    }
}
