<#
.SYNOPSIS
    Loads the service's release-health skill configuration and error classification (dot-source).

.DESCRIPTION
    Get-HealthConfig            reads <skillPath>/health-config.json, validates it against
                                zed-agent/health-config.schema.json, applies defaults and loads
                                every referenced KQL file.
    Get-HealthErrorClassification
                                builds the error-code -> user-error map from the configured source
                                (ADO Git XML or local XML), pinned by commit and cached on disk so
                                every check of a release uses the same classification.
#>

$script:HealthSkillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))          # .github/skills/zed-agent
$script:HealthRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..'))   # repo root

function Get-HealthRepoRoot { $script:HealthRepoRoot }

function Read-HealthServiceConfig {
    param([string]$RepoRoot = $script:HealthRepoRoot)
    $p = Join-Path $RepoRoot '.github\skills\zed-agent\service-config.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "service-config.json not found at $p" }
    Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Set-HealthDefault {
    param($Object, [string]$Name, $Value)
    if (-not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Get-HealthConfig {
    param([string]$RepoRoot = $script:HealthRepoRoot, [string]$SkillPath, $ServiceConfig, [switch]$SkipSchema)
    if (-not $SkillPath) {
        if (-not $ServiceConfig) { $ServiceConfig = Read-HealthServiceConfig -RepoRoot $RepoRoot }
        if (-not $ServiceConfig.releaseHealth -or -not $ServiceConfig.releaseHealth.skillPath) { throw "service-config.json has no releaseHealth.skillPath. Run 'setup-service group 11'." }
        $SkillPath = [string]$ServiceConfig.releaseHealth.skillPath
    }
    $skillDir = if ([System.IO.Path]::IsPathRooted($SkillPath)) { $SkillPath } else { Join-Path $RepoRoot $SkillPath }
    $cfgPath = Join-Path $skillDir 'health-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { throw "health-config.json not found in $skillDir" }
    $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
    if (-not $SkipSchema) {
        $schema = Join-Path $script:HealthSkillRoot 'health-config.schema.json'
        $errs = $null
        $ok = Test-Json -Json $raw -SchemaFile $schema -ErrorVariable errs -ErrorAction SilentlyContinue
        if (-not $ok) { throw "health-config.json does not match health-config.schema.json: $(($errs | ForEach-Object { $_.Exception.Message }) -join '; ')" }
    }
    $cfg = $raw | ConvertFrom-Json

    foreach ($n in 'scope', 'version', 'timing', 'comparison', 'rca') { Set-HealthDefault $cfg $n ([pscustomobject]@{}) }
    Set-HealthDefault $cfg 'signatureNormalization' @()
    Set-HealthDefault $cfg 'suppressions' @()
    Set-HealthDefault $cfg.dataSource 'queryTimeoutMinutes' 15
    Set-HealthDefault $cfg.dataSource 'maxRows' 500000
    $s = $cfg.scope
    Set-HealthDefault $s 'unitPrefixRegex' '^([^-]+)'; Set-HealthDefault $s 'canaryUnits' @(); Set-HealthDefault $s 'excludeVersionPatterns' @()
    Set-HealthDefault $s 'waveGapMinutes' 180; Set-HealthDefault $s 'activeWithinMinutes' 180; Set-HealthDefault $s 'stageLabels' 'ev2'
    $t = $cfg.timing
    foreach ($kv in @(@('firstCheckAfterT0Minutes', 45), @('tripwireIntervalMinutes', 30), @('planIntervalMinutes', 15), @('ingestionLagMinutes', 20),
                      @('windowStartOffsetMinutes', 15), @('maxWindowHours', 24), @('workloadCycleHours', 4), @('minCyclesForVerdict', 2), @('cohortLookbackDays', 10))) { Set-HealthDefault $t $kv[0] $kv[1] }
    Set-HealthDefault $t 'minBakeHours' ([pscustomobject]@{ canary = 12; default = 8 })
    Set-HealthDefault $t 'finalVerdictAfterHours' ([pscustomobject]@{ canary = 24; default = 24 })
    $c = $cfg.comparison
    foreach ($kv in @(@('baseWindow', 'previousDay'), @('confirmWindow', 'previousWeek'), @('investigateRelativeDelta', 0.10), @('falseDiscoveryRate', 0.01),
                      @('minExtraFailures', 20), @('singleSubscriptionShare', 0.8), @('controlEnabled', $true), @('controlPurityMin', 0.99))) { Set-HealthDefault $c $kv[0] $kv[1] }
    Set-HealthDefault $cfg.rca 'drilldowns' @(); Set-HealthDefault $cfg.rca 'maxRows' 500
    if (-not $cfg.PSObject.Properties['freshness'] -or -not $cfg.freshness) { $cfg | Add-Member -NotePropertyName freshness -NotePropertyValue $null -Force }
    elseif (-not $cfg.freshness.maxLagMinutes) { $cfg.freshness | Add-Member -NotePropertyName maxLagMinutes -NotePropertyValue 30 -Force }
    foreach ($sig in @($cfg.signals)) {
        Set-HealthDefault $sig 'enabled' $true; Set-HealthDefault $sig 'tiers' @('checkpoint', 'final'); Set-HealthDefault $sig 'includeControl' $true
        Set-HealthDefault $sig 'params' ([pscustomobject]@{}); Set-HealthDefault $sig 'thresholds' ([pscustomobject]@{})
        if (-not $sig.PSObject.Properties['windows'] -or -not $sig.windows) {
            $w = switch ($sig.kind) { 'series' { @('current') } 'lifecycle' { @('current') } 'signatures' { @('current', [string]$c.baseWindow) } default { @('current', 'previousDay', 'previousWeek') } }
            $sig | Add-Member -NotePropertyName windows -NotePropertyValue @($w | Select-Object -Unique) -Force
        }
    }

    # Load every referenced KQL file once.
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($cfg.cohortQuery, $cfg.exposureQuery)) { $files.Add([string]$f) }
    if ($cfg.freshness) { $files.Add([string]$cfg.freshness.queryFile) }
    foreach ($sig in @($cfg.signals)) { foreach ($p in 'queryFile', 'historyQueryFile', 'startFailureQueryFile') { if ($sig.$p) { $files.Add([string]$sig.$p) } } }
    foreach ($d in @($cfg.rca.drilldowns)) { if ($d.queryFile) { $files.Add([string]$d.queryFile) } }
    $queries = @{}
    foreach ($f in ($files | Select-Object -Unique)) {
        $qp = Join-Path $skillDir $f
        if (-not (Test-Path -LiteralPath $qp)) { throw "Query file '$f' referenced by health-config.json was not found in $skillDir" }
        $queries[$f] = Get-Content -LiteralPath $qp -Raw -Encoding UTF8
    }
    foreach ($sig in @($cfg.signals)) {
        if ($sig.kind -eq 'signatures' -and -not $sig.historyQueryFile) { throw "Signal '$($sig.id)' (signatures) needs historyQueryFile (new signatures are confirmed against other builds)." }
        if ($sig.kind -eq 'counters' -and @($sig.counters).Count -eq 0) { throw "Signal '$($sig.id)' (counters) needs at least one entry in counters." }
    }
    if (@($cfg.signals | Select-Object -ExpandProperty id | Group-Object | Where-Object Count -gt 1).Count) { throw 'Signal ids in health-config.json must be unique.' }

    [pscustomobject]@{ Config = $cfg; SkillDir = $skillDir; SkillPath = $SkillPath; ConfigPath = $cfgPath; Queries = $queries }
}

function Get-HealthAdoToken {
    $job = Start-Job -ScriptBlock { az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>&1 }
    if (-not (Wait-Job $job -Timeout 60)) { Stop-Job $job; Remove-Job $job -Force; throw 'ADO token acquisition timed out' }
    $t = (Receive-Job $job) -join ''; Remove-Job $job -Force
    if ($t -notmatch '^ey') { throw "ADO token acquisition failed: $t" }
    $t
}

function ConvertFrom-HealthErrorXml {
    param([Parameter(Mandatory)][string]$XmlText, $Source)
    $item = if ($Source.itemElement) { [string]$Source.itemElement } else { 'Error' }
    $nameEl = if ($Source.nameElement) { [string]$Source.nameElement } else { 'Name' }
    $userEl = if ($Source.userErrorElement) { [string]$Source.userErrorElement } else { 'UserError' }
    $doc = [System.Xml.XmlDocument]::new()
    $doc.XmlResolver = $null
    $doc.LoadXml($XmlText.TrimStart([char]0xFEFF))
    $map = @{}
    foreach ($e in $doc.SelectNodes("//*[local-name()='$item']")) {
        $n = $e.SelectSingleNode("*[local-name()='$nameEl']"); if (-not $n) { continue }
        $u = $e.SelectSingleNode("*[local-name()='$userEl']")
        $map[$n.InnerText.Trim()] = [bool]($u -and $u.InnerText.Trim() -eq 'true')
    }
    $map
}

<#
  Returns @{ Map = hashtable code -> isUserError; Commit; Source; Count }.
  -PinnedCommit reuses the classification a release started with (state.releaseHealth.errorClassificationCommit).
#>
function Get-HealthErrorClassification {
    param($Config, [string]$RepoRoot = $script:HealthRepoRoot, [string]$PinnedCommit, [string]$CacheDir)
    $src = $Config.errorClassification.source
    if (-not $CacheDir) { $CacheDir = Join-Path $RepoRoot '.zed-agent\cache\error-classification' }
    switch ($src.type) {
        'none' { return @{ Map = @{}; Commit = $null; Source = 'none'; Count = 0 } }
        'local-xml' {
            $p = Join-Path $RepoRoot ([string]$src.localPath)
            $map = ConvertFrom-HealthErrorXml -XmlText (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -Source $src
            return @{ Map = $map; Commit = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant(); Source = $p; Count = $map.Count }
        }
        'ado-git-xml' {
            if ($PinnedCommit) {
                $cache = Join-Path $CacheDir "$PinnedCommit.json"
                if (Test-Path -LiteralPath $cache) {
                    $h = @{}; (Get-Content -LiteralPath $cache -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = [bool]$_.Value }
                    return @{ Map = $h; Commit = $PinnedCommit; Source = "$($src.repository):$($src.path)"; Count = $h.Count }
                }
            }
            $vType = if ($PinnedCommit) { 'commit' } else { 'branch' }
            $ver = if ($PinnedCommit) { $PinnedCommit } else { if ($src.branch) { [string]$src.branch } else { 'develop' } }
            $uri = "https://dev.azure.com/$($src.organization)/$([uri]::EscapeDataString([string]$src.project))/_apis/git/repositories/$([uri]::EscapeDataString([string]$src.repository))/items" +
                   "?path=$([uri]::EscapeDataString([string]$src.path))&versionDescriptor.versionType=$vType&versionDescriptor.version=$([uri]::EscapeDataString($ver))&includeContent=true&`$format=json&api-version=7.1"
            $resp = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $(Get-HealthAdoToken)" } -TimeoutSec 120 -ErrorAction Stop
            $map = ConvertFrom-HealthErrorXml -XmlText ([string]$resp.content) -Source $src
            $commit = [string]$resp.commitId
            New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
            $map | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $CacheDir "$commit.json") -Encoding UTF8
            return @{ Map = $map; Commit = $commit; Source = "$($src.repository):$($src.path)@$($src.branch)"; Count = $map.Count }
        }
        default { throw "Unknown errorClassification.source.type '$($src.type)'" }
    }
}
