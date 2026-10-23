<#
.SYNOPSIS
    Release names for services that ship several releases per month
    (service-config.json → releaseNaming, e.g. BCM: BCM2610, BCM2610_2, BCM2610_3).

.DESCRIPTION
    The release name becomes the release id everywhere: .zed-agent/releases/<name>/, state,
    email/Teams subjects, the watcher, and the {{releaseName}} / {{releaseNameLower}} config
    tokens (commit tracker sheet, revert branch, RI/FI branches, SafeFly title).

    Actions
      Suggest   Next free name for -Month (default: current month): <prefix><YYMM> when no
                release of that month exists yet, else <prefix><YYMM><sep><n+1>. Also returns
                the existing releases of that month and every release still active.
      Validate  -Name → parsed name (canonical case, releaseMonth, sequence) + Available
                ($false if a release folder with that name already exists).

.OUTPUTS
    PSCustomObject: Success, Action, Enabled, Suggested, Name, ReleaseMonth, YYMM, Sequence,
    Available, Existing[], Active[], Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Suggest', 'Validate')][string]$Action,
    [string]$Name,
    [string]$Month,
    [string]$RepoRoot = (Get-Location).Path,
    [string]$ServiceConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ReleaseNameLib.ps1')

$out = [pscustomobject]@{ Success = $false; Action = $Action; Enabled = $false; Suggested = $null; Name = $null; ReleaseMonth = $null; YYMM = $null; Sequence = $null; Available = $null; Existing = @(); Active = @(); Error = $null }

function Get-Releases {
    $list = @()
    foreach ($base in @('.zed-release', '.zed-agent')) {
        $dir = Join-Path $RepoRoot "$base/releases"
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $dir -Directory) {
            $rel = $null; $st = $null
            try { $rel = Get-Content -LiteralPath (Join-Path $d.FullName 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            try { $st = Get-Content -LiteralPath (Join-Path $d.FullName 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            $list += [pscustomobject]@{ id = $d.Name; release = $rel; status = $(if ($st) { [string]$st.status } else { $null }); testMode = [bool]($rel -and $rel.testMode) }
        }
    }
    return $list
}

try {
    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $naming = Get-ReleaseNamingConfig $svc
    $out.Enabled = [bool]$naming
    if (-not $naming) { throw 'service-config.json → releaseNaming is not configured (release id stays YYYY-MM).' }

    $releases = @(Get-Releases)
    $out.Active = @($releases | Where-Object { $_.status -and $_.status -notin @('completed', 'stopped') -and -not $_.testMode } | ForEach-Object { $_.id } | Select-Object -Unique)

    switch ($Action) {
        'Suggest' {
            $m = if ($Month) { $Month } else { (Get-Date).ToString('yyyy-MM') }
            if ($m -notmatch '^(\d{4})-(\d{2})$') { throw "-Month '$Month' must be YYYY-MM." }
            $yymm = $Matches[1].Substring(2) + $Matches[2]
            $seqs = @()
            foreach ($r in $releases) {
                # a release set up before releaseNaming ('2026-10') is that month's first release
                if ($r.id -eq $m -and -not $r.testMode) { $seqs += 1; $out.Existing += "$($r.id) (= $($naming.prefix)$yymm)"; continue }
                try { $p = ConvertFrom-ReleaseName $r.id $naming } catch { continue }
                if ($p.yymm -eq $yymm) { $seqs += $p.sequence; $out.Existing += $p.releaseName }
            }
            $next = if ($seqs.Count -eq 0) { 1 } else { ([int]($seqs | Measure-Object -Maximum).Maximum) + 1 }
            $out.Suggested = "$($naming.prefix)$yymm" + $(if ($next -gt 1) { "$($naming.separator)$next" } else { '' })
            $out.ReleaseMonth = $m; $out.YYMM = $yymm; $out.Sequence = $next
        }
        'Validate' {
            if (-not $Name) { throw '-Name is required.' }
            $p = ConvertFrom-ReleaseName $Name $naming
            $out.Name = $p.releaseName; $out.ReleaseMonth = $p.releaseMonth; $out.YYMM = $p.yymm; $out.Sequence = $p.sequence
            # the first name of a month is taken if that month already has a pre-releaseNaming release ('2026-10')
            $legacyFirst = $p.sequence -eq 1 -and @($releases | Where-Object { $_.id -eq $p.releaseMonth -and -not $_.testMode }).Count -gt 0
            $out.Available = -not (@($releases | Where-Object { $_.id -ieq $p.releaseName }).Count) -and -not $legacyFirst
            $out.Existing = @($releases | ForEach-Object {
                if ($_.id -eq $p.releaseMonth -and -not $_.testMode) { "$($_.id) (= $($naming.prefix)$($p.yymm))" }
                else { try { $q = ConvertFrom-ReleaseName $_.id $naming; if ($q.yymm -eq $p.yymm) { $q.releaseName } } catch { } }
            })
        }
    }
    $out.Success = $true
} catch {
    $out.Error = $_.Exception.Message
}
return $out
