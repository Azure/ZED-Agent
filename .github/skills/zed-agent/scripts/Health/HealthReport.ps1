<#
.SYNOPSIS
    Renders release health reports (dot-source).

.DESCRIPTION
    Get-HealthSubject           email subject for a report (verdict / early-warning / interim).
    ConvertTo-HealthReportHtml  HTML body from a report produced by Invoke-ReleaseHealthCheck.ps1,
                                using templates/release-health-email.html (via Expand-Template).
                                RCA blocks added by the agent (finding.rca) are rendered too.
#>

. (Join-Path $PSScriptRoot '..\Expand-Template.ps1')

function ConvertTo-HealthHtmlText([AllowNull()]$Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value).Replace('{{', '&#123;&#123;').Replace('}}', '&#125;&#125;') }

function Get-HealthVerdictStyle {
    param([string]$Verdict, [string]$Kind)
    if ($Kind -eq 'early-warning') { return @{ Color = '#d13438'; Emoji = '⚠️'; Text = 'EARLY WARNING' } }
    if ($Kind -eq 'interim') { return @{ Color = '#605e5c'; Emoji = '🔎'; Text = 'CHECKPOINT' } }
    switch ($Verdict) {
        'GO'           { @{ Color = '#107c10'; Emoji = '🟢'; Text = 'GO' } }
        'HOLD'         { @{ Color = '#ca5010'; Emoji = '🟠'; Text = 'HOLD' } }
        'NO-GO'        { @{ Color = '#d13438'; Emoji = '🔴'; Text = 'NO-GO' } }
        default        { @{ Color = '#605e5c'; Emoji = '⚪'; Text = 'INCONCLUSIVE' } }
    }
}

function Get-HealthSubject {
    param([Parameter(Mandatory)]$Report, [ValidateSet('verdict', 'early-warning', 'interim')][string]$Kind = 'verdict', [string]$ReleaseName)
    $st = Get-HealthVerdictStyle -Verdict $Report.verdict.verdict -Kind $Kind
    $name = if ($ReleaseName) { $ReleaseName } elseif ($Report.releaseId) { $Report.releaseId } else { $Report.releaseVersion }
    switch ($Kind) {
        'early-warning' { "[ZED] $($st.Emoji) Early warning — $($Report.wave.label) health | $name" }
        'interim'       { "[ZED] $($st.Emoji) Health checkpoint — $($Report.wave.label) | $name" }
        default         { "[ZED] $($st.Emoji) $($st.Text) — $($Report.wave.label) health | $name" }
    }
}

function Format-HealthPct($v, [int]$Digits = 3) { if ($null -eq $v) { 'n/a' } else { ("{0:p$Digits}" -f [double]$v) } }
function Format-HealthX($v) { if ($null -eq $v) { 'n/a' } elseif ([double]$v -ge 1e8) { 'new' } else { '{0:n2}x' -f [double]$v } }

function Get-HealthSignalNumbers {
    param($Signal)
    $s = $Signal.summary
    if (-not $s) { return '' }
    switch ($Signal.kind) {
        'outcomes'   { 'service failures {0} vs {1} ({2}; control {3}) · volume {4:n0} vs {5:n0}' -f (Format-HealthPct $s.serviceRate), (Format-HealthPct $s.baseServiceRate), (Format-HealthX $s.ratio), (Format-HealthX $s.controlRatio), $s.volume, $s.baseVolume }
        'latency'    { '{0} operations compared; worst change {1}' -f $s.operations, (Format-HealthX $s.worstRatio) }
        'signatures' { '{0:n0} vs {1:n0} errors per million operations ({2}); {3} signatures' -f $s.errorsPerMillionOps, $s.baseErrorsPerMillionOps, (Format-HealthX $s.ratio), $s.signatures }
        'counters'   { (@($s.PSObject.Properties | ForEach-Object { '{0}: {1:n1} vs {2:n1} ({3})' -f $_.Name, $_.Value.current, $_.Value.base, (Format-HealthX $_.Value.ratio) }) -join ' · ') }
        'series'     { 'max growth {0:n2}%/h' -f [double]$s.maxGrowthPctPerHour }
        'lifecycle'  { '{0}/{1} stamps initialized ({2} instances); role start failures {3}' -f $s.unitsInitialized, $s.units, $s.instances, $s.startFailures }
        default      { '' }
    }
}

function ConvertTo-HealthFindingRows {
    param([object[]]$Findings, $Report)
    $links = @{}; foreach ($q in @($Report.queries)) { if ($q.adxLink) { $links[[string]$q.name] = [string]$q.adxLink } }
    $rows = foreach ($f in $Findings) {
        $ev = if ($links[[string]$f.query]) { "<a href=`"$(ConvertTo-HealthHtmlText $links[[string]$f.query])`">query</a>" } else { '' }
        $rca = ''
        if ($f.rca) {
            $rca = "<br><b>RCA</b> ($(ConvertTo-HealthHtmlText $f.rca.classification), confidence $(ConvertTo-HealthHtmlText $f.rca.confidence)): $(ConvertTo-HealthHtmlText $f.rca.summary)"
            if ($f.rca.suspects) { $rca += "<br><b>Suspect changes:</b> $(ConvertTo-HealthHtmlText (@($f.rca.suspects) -join '; '))" }
            if ($f.rca.recommendation) { $rca += "<br><b>Recommendation:</b> $(ConvertTo-HealthHtmlText $f.rca.recommendation)" }
        }
        $units = if (@($f.units).Count) { '<br><i>' + (ConvertTo-HealthHtmlText ((@($f.units) | Select-Object -First 12) -join ', ')) + '</i>' } else { '' }
        "<tr><td>$(ConvertTo-HealthHtmlText $f.severity)</td><td>$(ConvertTo-HealthHtmlText $f.area)</td><td><b>$(ConvertTo-HealthHtmlText $f.title)</b><br>$(ConvertTo-HealthHtmlText $f.detail)$units$rca</td><td>$ev</td></tr>"
    }
    $rows -join "`n"
}

function ConvertTo-HealthReportHtml {
    param([Parameter(Mandatory)]$Report, [ValidateSet('verdict', 'early-warning', 'interim')][string]$Kind = 'verdict', [string]$ReleaseName, [string]$TemplatePath)
    if (-not $TemplatePath) { $TemplatePath = Join-Path $PSScriptRoot '..\..\templates\release-health-email.html' }
    $st = Get-HealthVerdictStyle -Verdict $Report.verdict.verdict -Kind $Kind
    $name = if ($ReleaseName) { $ReleaseName } elseif ($Report.releaseId) { $Report.releaseId } else { $Report.releaseVersion }
    $w = $Report.wave
    $banner = switch ($Kind) {
        'early-warning' { "$($st.Emoji) EARLY WARNING — serious health signal on $($w.label). Investigate now; the stage is still baking." }
        'interim'       { "$($st.Emoji) CHECKPOINT — $($w.label) after $('{0:n1}' -f $w.ageHours) h ($($w.cycles) workload cycle(s)). Findings need attention." }
        default {
            switch ($Report.verdict.verdict) {
                'GO'    { "$($st.Emoji) GO — no release regression found on $($w.label)." }
                'HOLD'  { "$($st.Emoji) HOLD — $($w.label) needs an owner decision before promotion." }
                'NO-GO' { "$($st.Emoji) NO-GO — do not promote. A serious regression was found on $($w.label)." }
                default { "$($st.Emoji) INCONCLUSIVE — not enough reliable data for $($w.label) yet. Treat as not GO." }
            }
        }
    }
    $t0 = if ($w.t0First -eq $w.t0Last) { "$($w.t0First)" } else { "$($w.t0First) → $($w.t0Last)" }
    $scope = "<b>Build:</b> $(ConvertTo-HealthHtmlText $Report.releaseVersion) (previous: $(ConvertTo-HealthHtmlText $Report.previousVersion))<br>" +
             "<b>Stage:</b> $(ConvertTo-HealthHtmlText $w.label) — $(@($w.units).Count) stamp(s): $(ConvertTo-HealthHtmlText ((@($w.units) | Select-Object -First 30) -join ', '))<br>" +
             "<b>Switched to the new build (telemetry):</b> $(ConvertTo-HealthHtmlText $t0) UTC · <b>Observed:</b> $('{0:n1}' -f [double]$w.ageHours) h, $($w.cycles) workload cycle(s) · <b>Check:</b> $(ConvertTo-HealthHtmlText $Report.tier) as of $(ConvertTo-HealthHtmlText $Report.asOf)<br>" +
             "<b>Control:</b> $(@($Report.control.units).Count) stamp(s) still on the previous build<br><br>"
    $reasons = '<ul>' + ((@($Report.verdict.reasons) | ForEach-Object { "<li>$(ConvertTo-HealthHtmlText $_)</li>" }) -join '') + '</ul>'
    if ($Report.agentNotes) { $reasons += "<p>$(ConvertTo-HealthHtmlText $Report.agentNotes)</p>" }
    $statusEmoji = @{ pass = '✅'; warn = '⚠️'; fail = '❌'; error = '⚪' }
    $score = (@($Report.signals) | ForEach-Object {
        "<tr><td>$(ConvertTo-HealthHtmlText $_.area)</td><td>$(ConvertTo-HealthHtmlText $_.title)</td><td>$($statusEmoji[[string]$_.status]) $(ConvertTo-HealthHtmlText $_.status)</td><td>$(ConvertTo-HealthHtmlText (Get-HealthSignalNumbers $_))</td></tr>"
    }) -join "`n"
    $open = @($Report.findings | Where-Object { $_.severity -in 'Sev1', 'Investigate', 'Inconclusive' -and -not $_.suppressed -and -not $_.accepted })
    $head = '<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse; font-family:Segoe UI,Arial,sans-serif; font-size:13px;"><tr style="background:#1f3a5f; color:#ffffff;"><th>Severity</th><th>Area</th><th>Finding</th><th>Evidence</th></tr>'
    $findingsHtml = if ($open.Count) { "<b>Findings</b><br>$head$(ConvertTo-HealthFindingRows $open $Report)</table><br>" } else { '<b>Findings</b><br>None.<br><br>' }
    $watch = @($Report.findings | Where-Object { $_.severity -eq 'Watch' -or $_.suppressed -or $_.accepted })
    $watchHtml = if ($watch.Count) { "<b>Watch items</b> <i>(not blocking: customer-concentrated, accepted or suppressed)</i><br>$head$(ConvertTo-HealthFindingRows $watch $Report)</table><br>" } else { '' }
    $dq = $Report.dataQuality
    $dqItems = @()
    foreach ($i in @($dq.issues)) { $dqItems += "<li>⚠️ $(ConvertTo-HealthHtmlText $i)</li>" }
    foreach ($n in @($dq.notes)) { $dqItems += "<li>$(ConvertTo-HealthHtmlText $n)</li>" }
    foreach ($fr in @($dq.freshness)) { $dqItems += "<li>$(ConvertTo-HealthHtmlText $fr.Source): ingestion lag $(ConvertTo-HealthHtmlText $fr.LagMinutes) min</li>" }
    if ($Report.classification) { $dqItems += "<li>Error classification: $(ConvertTo-HealthHtmlText $Report.classification.source) @ $(ConvertTo-HealthHtmlText $Report.classification.commit) ($($Report.classification.count) codes)</li>" }
    $dqHtml = if ($dqItems.Count) { "<b>Data quality</b><ul>$($dqItems -join '')</ul>" } else { '' }
    $linkItems = @()
    foreach ($q in @($Report.queries | Where-Object adxLink)) { $linkItems += "<a href=`"$(ConvertTo-HealthHtmlText $q.adxLink)`">$(ConvertTo-HealthHtmlText $q.name)</a>" }
    if ($Report.config.dashboardUrl) { $linkItems += "<a href=`"$(ConvertTo-HealthHtmlText $Report.config.dashboardUrl)`">Service health dashboard</a>" }
    $linksHtml = if ($linkItems.Count) { "<b>Evidence (Azure Data Explorer)</b><br>$($linkItems -join ' · ')<br><br>" } else { '' }
    $footer = "Sent by ZED release health ($($Report.config.mode) mode). NO-GO is a recommendation only — ZED never stops, rolls back or promotes a rollout. Owner commands: health accept <findingId> `"<reason>`" · health override <stage> go `"<reason>`" · health feedback <findingId> false-positive `"<reason>`"."
    Expand-Template -TemplatePath $TemplatePath -Variables @{
        headline = "Release health — $name — $($w.label)"; bannerColor = $st.Color; bannerText = $banner; scopeHtml = $scope; reasonsHtml = $reasons
        scorecardRows = $score; findingsHtml = $findingsHtml; watchHtml = $watchHtml; dataQualityHtml = $dqHtml; linksHtml = $linksHtml; footerText = (ConvertTo-HealthHtmlText $footer)
    }
}
