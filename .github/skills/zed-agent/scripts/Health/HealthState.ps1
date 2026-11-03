<#
.SYNOPSIS
    Release-state helpers for the release health check (dot-source).

.DESCRIPTION
    Get-HealthReleaseInfo   release id / build number / branch from state.json
    Get-HealthStageMap      unit -> EV2 stage label (e.g. 'Day2') from state.ev2Diagnostics,
                            mapped region -> stamp prefix via service-config.stampPrefixToRegion
                            and AzureServiceConfig (Get-RegionMapping.ps1, cached). Best effort:
                            returns an empty map when nothing is available (waves become 'Wave N').
    Test-HealthStageComplete
                            true when an EV2 stage tracker reports the stage complete.
#>

function Get-HealthReleaseInfo {
    param([Parameter(Mandatory)]$State, [string]$ReleaseId)
    $build = [string]$State.buildNumber
    $branch = [string]$State.branch
    if (-not $build -and $State.PSObject.Properties['release'] -and $State.release) { $build = [string]$State.release.buildNumber }
    [pscustomobject]@{ ReleaseId = $(if ($ReleaseId) { $ReleaseId } else { [string]$State.releaseId }); BuildNumber = $build; Branch = $branch }
}

function Get-HealthPrefixRegionMap {
    param($ServiceConfig, [string]$ScriptsDir)
    $map = @{}
    if ($ServiceConfig -and $ServiceConfig.PSObject.Properties['stampPrefixToRegion'] -and $ServiceConfig.stampPrefixToRegion) {
        foreach ($p in $ServiceConfig.stampPrefixToRegion.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    }
    try {
        $rm = Join-Path $ScriptsDir 'Get-RegionMapping.ps1'
        if (Test-Path -LiteralPath $rm) {
            foreach ($cloud in 'Public', 'Canary') {
                foreach ($r in @(& $rm -CloudName $cloud 2>$null)) {
                    if ($r.StampPrefix -and $r.RegionShortName -and -not $map.ContainsKey([string]$r.StampPrefix)) { $map[[string]$r.StampPrefix] = [string]$r.RegionShortName }
                }
            }
        }
    } catch { }
    $map
}

function Get-HealthStageMap {
    param($State, [string[]]$Units, [string]$UnitPrefixRegex = '^([^-]+)', [hashtable]$PrefixRegionMap = @{})
    $regionStage = @{}
    foreach ($d in @($State.ev2Diagnostics)) {
        if (-not $d) { continue }
        foreach ($bucket in 'completedNodes', 'inProgressNodes', 'waitingNodes', 'failedNodes') {
            foreach ($n in @($d.$bucket)) { if ($n -and $n.name -and $n.sdpNode -and -not $regionStage.ContainsKey([string]$n.name)) { $regionStage[[string]$n.name] = [string]$n.sdpNode } }
        }
    }
    $map = @{}
    if (-not $regionStage.Count) { return $map }
    foreach ($u in @($Units)) {
        if ($u -notmatch $UnitPrefixRegex) { continue }
        $region = $PrefixRegionMap[$Matches[1]]
        if ($region -and $regionStage.ContainsKey($region)) { $map[$u] = $regionStage[$region] }
    }
    $map
}

function Test-HealthStageComplete {
    param($State, [string]$Label)
    if (-not $Label -or -not $State -or -not $State.PSObject.Properties['step15'] -or -not $State.step15) { return $false }
    $tracker = $State.step15.ev2StageTracker
    if (-not $tracker) { return $false }
    foreach ($p in $tracker.PSObject.Properties) { if (@($p.Value.stagesComplete) -contains $Label) { return $true } }
    $false
}
