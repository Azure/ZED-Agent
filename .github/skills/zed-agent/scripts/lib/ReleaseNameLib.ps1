# Release naming helpers (service-config.json → releaseNaming).
#
# Services that ship more than one release per month name each release explicitly, e.g. BCM:
#   BCM2610, BCM2610_2, BCM2610_3   = <prefix><YYMM>[<separator><sequence>]
# The release name IS the release id (folder .zed-agent/releases/<name>/, state, emails, watcher).
# The release month is kept separately (release.json → releaseMonth = 'YYYY-MM'), so {{YYMM}}
# never has to be parsed out of the id. Without releaseNaming the id stays 'YYYY-MM'.

function Get-ReleaseNamingConfig($Svc) {
    if (-not $Svc -or -not $Svc.PSObject.Properties['releaseNaming'] -or -not $Svc.releaseNaming) { return $null }
    $rn = $Svc.releaseNaming
    if ($rn.PSObject.Properties['enabled'] -and $rn.enabled -eq $false) { return $null }
    $prefix = [string]$rn.prefix
    if (-not $prefix -or $prefix -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "releaseNaming.prefix '$prefix' must be letters/digits starting with a letter (e.g. 'BCM')." }
    $sep = if ($rn.PSObject.Properties['sequenceSeparator'] -and $rn.sequenceSeparator) { [string]$rn.sequenceSeparator } else { '_' }
    if ($sep -notmatch '^[_.-]$') { throw "releaseNaming.sequenceSeparator '$sep' must be one of _ . -" }
    [pscustomobject]@{
        prefix    = $prefix
        separator = $sep
        regex     = "^(?i:$([regex]::Escape($prefix)))(?<yy>[0-9]{2})(?<mm>[0-9]{2})(?:$([regex]::Escape($sep))(?<seq>[0-9]+))?$"
    }
}

# Name → { releaseName (canonical prefix case), releaseMonth, yyyy, mm, yymm, sequence }. Throws if invalid.
function ConvertFrom-ReleaseName([string]$Name, $Naming) {
    if (-not $Naming) { throw 'releaseNaming is not configured.' }
    $n = "$Name".Trim()
    $m = [regex]::Match($n, $Naming.regex)
    if (-not $m.Success) {
        throw "Release name '$Name' does not match $($Naming.prefix)<YYMM>[$($Naming.separator)<n>] (e.g. $($Naming.prefix)2610, $($Naming.prefix)2610$($Naming.separator)2)."
    }
    $mm = [int]$m.Groups['mm'].Value
    if ($mm -lt 1 -or $mm -gt 12) { throw "Release name '$Name': month '$($m.Groups['mm'].Value)' is not 01-12." }
    $seq = if ($m.Groups['seq'].Success) { [int]$m.Groups['seq'].Value } else { 1 }
    if ($m.Groups['seq'].Success -and $seq -lt 2) { throw "Release name '$Name': the first release of a month has no suffix; later ones are $($Naming.separator)2, $($Naming.separator)3, …" }
    $yyyy = 2000 + [int]$m.Groups['yy'].Value
    $yymm = $m.Groups['yy'].Value + $m.Groups['mm'].Value
    $canon = "$($Naming.prefix)$yymm" + $(if ($seq -gt 1) { "$($Naming.separator)$seq" } else { '' })
    [pscustomobject]@{
        releaseName  = $canon
        releaseMonth = ('{0:0000}-{1:00}' -f $yyyy, $mm)
        yyyy         = ('{0:0000}' -f $yyyy)
        mm           = ('{0:00}' -f $mm)
        yymm         = $yymm
        sequence     = $seq
    }
}

# { yyyy, mm, yymm } of a release: release.json → releaseMonth, else a 'YYYY-MM' inside the id
# (2026-10, TEST-2026-10-i3), else a release name '<letters><YYMM>[sep n]'. Throws if none.
function Get-ReleaseMonthParts([string]$ReleaseId, $Release) {
    $src = $null
    if ($Release -and $Release.PSObject.Properties['releaseMonth'] -and $Release.releaseMonth) { $src = [string]$Release.releaseMonth }
    if ($src -and $src -match '^(\d{4})-(\d{2})$') { return [pscustomobject]@{ yyyy = $Matches[1]; mm = $Matches[2]; yymm = $Matches[1].Substring(2) + $Matches[2] } }
    if ("$ReleaseId" -match '(?:^|\D)(\d{4})-(\d{2})(?:\D|$)') { return [pscustomobject]@{ yyyy = $Matches[1]; mm = $Matches[2]; yymm = $Matches[1].Substring(2) + $Matches[2] } }
    if ("$ReleaseId" -match '^[A-Za-z]+(\d{2})(\d{2})(?:[_.-]\d+)?$' -and [int]$Matches[2] -ge 1 -and [int]$Matches[2] -le 12) {
        return [pscustomobject]@{ yyyy = "20$($Matches[1])"; mm = $Matches[2]; yymm = $Matches[1] + $Matches[2] }
    }
    throw "Cannot determine the release month of '$ReleaseId' (expected release.json → releaseMonth 'YYYY-MM', an id 'YYYY-MM' or a release name like BCM2610_2)."
}

# Expands the release tokens used in config templates:
#   {{YYMM}} {{YYYY}} {{MM}} {{releaseId}} {{releaseName}} {{releaseNameLower}} {{releaseTag}} {ownerAlias}/{{ownerAlias}}
# releaseName = release.json → releaseName, else the release id. releaseTag = release.json →
# releaseTag, else the leaf of currentBranch, else the lowercased release name / YYMM.
function Expand-ReleaseTokens([string]$Template, [string]$ReleaseId, $Release, [string]$OwnerAlias) {
    $t = "$Template"
    if ($t -match '\{\{(YYMM|YYYY|MM)\}\}') {
        $p = Get-ReleaseMonthParts $ReleaseId $Release
        $t = $t.Replace('{{YYMM}}', $p.yymm).Replace('{{YYYY}}', $p.yyyy).Replace('{{MM}}', $p.mm)
    }
    $name = if ($Release -and $Release.PSObject.Properties['releaseName'] -and $Release.releaseName) { [string]$Release.releaseName } else { $ReleaseId }
    if ($t.Contains('{{releaseTag}}')) {
        $tag = if ($Release -and $Release.PSObject.Properties['releaseTag'] -and $Release.releaseTag) { [string]$Release.releaseTag }
               elseif ($Release -and $Release.PSObject.Properties['releaseName'] -and $Release.releaseName) { ([string]$Release.releaseName).ToLowerInvariant() }
               elseif ($Release -and $Release.PSObject.Properties['currentBranch'] -and $Release.currentBranch) { ([string]$Release.currentBranch).Split('/')[-1] }
               else { (Get-ReleaseMonthParts $ReleaseId $Release).yymm }
        $t = $t.Replace('{{releaseTag}}', $tag)
    }
    if ($t -match '\{\{?ownerAlias\}\}?') {
        $alias = if ($OwnerAlias) { $OwnerAlias } elseif ($Release -and $Release.PSObject.Properties['releaseOwner'] -and $Release.releaseOwner -and $Release.releaseOwner.alias) { [string]$Release.releaseOwner.alias } else { 'zed' }
        $t = $t.Replace('{{ownerAlias}}', $alias).Replace('{ownerAlias}', $alias)
    }
    return $t.Replace('{{releaseNameLower}}', $name.ToLowerInvariant()).Replace('{{releaseName}}', $name).Replace('{{releaseId}}', $ReleaseId)
}
