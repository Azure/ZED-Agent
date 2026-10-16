# CommitTrackerLib.ps1 — pure helpers for Invoke-CommitTracker.ps1 (no I/O). Dot-sourced by the
# script and by its tests.

function ConvertTo-HeaderKey([string]$Header) {
    return (([string]$Header) -replace '\s+', '').ToLowerInvariant()
}

function Get-ColumnLetter([int]$Index) {
    # 0-based index -> A, B, ..., Z, AA, ...
    $n = $Index + 1; $s = ''
    while ($n -gt 0) { $m = ($n - 1) % 26; $s = [char](65 + $m) + $s; $n = [math]::Floor(($n - 1) / 26) }
    return $s
}

function Test-SheetName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Sheet name is empty.' }
    if ($Name.Length -gt 31) { return "Sheet name '$Name' is longer than 31 characters." }
    if ($Name -match '[\[\]:\*\?/\\]') { return "Sheet name '$Name' contains one of [ ] : * ? / \." }
    if ($Name.StartsWith("'") -or $Name.EndsWith("'")) { return "Sheet name '$Name' cannot start or end with an apostrophe." }
    return $null
}

function Expand-SheetName([string]$Template, [string]$ReleaseId) {
    if ($ReleaseId -notmatch '^(\d{4})-(\d{2})') { throw "ReleaseId '$ReleaseId' is not YYYY-MM." }
    $yymm = $Matches[1].Substring(2) + $Matches[2]
    return $Template.Replace('{{YYMM}}', $yymm).Replace('{{YYYY}}', $Matches[1]).Replace('{{MM}}', $Matches[2]).Replace('{{releaseId}}', $ReleaseId)
}

# Maps configured columns to their 0-based position in a header row. Returns
# @{ map = @{ <headerKey> = <index> }; missing = @(<header>, ...) }
function Get-HeaderMap([object[]]$HeaderRow, [object[]]$Columns) {
    $pos = @{}
    for ($i = 0; $i -lt $HeaderRow.Count; $i++) {
        $k = ConvertTo-HeaderKey ([string]$HeaderRow[$i])
        if ($k -and -not $pos.ContainsKey($k)) { $pos[$k] = $i }
    }
    $map = @{}; $missing = @()
    foreach ($c in $Columns) {
        $k = ConvertTo-HeaderKey $c.header
        $names = @($k)
        if ($c.PSObject.Properties['aliases'] -and $c.aliases) { $names += @($c.aliases | ForEach-Object { ConvertTo-HeaderKey $_ }) }
        $hit = @($names | Where-Object { $pos.ContainsKey($_) } | Select-Object -First 1)
        if ($hit.Count -gt 0) { $map[$k] = $pos[$hit[0]] } else { $missing += $c.header }
    }
    return @{ map = $map; missing = $missing }
}

# Identity of a tracker row from its link text: 'pr:<id>' or 'commit:<sha-prefix>' (lower-case), or $null.
function Get-RowKey([string]$LinkText) {
    if ([string]::IsNullOrWhiteSpace($LinkText)) { return $null }
    if ($LinkText -match '(?i)(?:pull\s*request|\bPR)\s*[#!:]?\s*(\d{4,})') { return "pr:$($Matches[1])" }
    if ($LinkText -match '(?i)/pullrequest/(\d+)') { return "pr:$($Matches[1])" }
    if ($LinkText -match '(?i)\bcommit\s*[:#]?\s*([0-9a-f]{7,40})\b') { return "commit:$($Matches[1].ToLowerInvariant())" }
    if ($LinkText -match '^\s*([0-9a-f]{7,40})\s*$') { return "commit:$($Matches[1].ToLowerInvariant())" }
    return $null
}

function Test-KeyPresent([string]$Key, [System.Collections.Generic.HashSet[string]]$Existing) {
    if ($Existing.Contains($Key)) { return $true }
    if ($Key -like 'commit:*') {
        $sha = $Key.Substring(7)
        foreach ($e in $Existing) {
            if ($e -like 'commit:*') {
                $o = $e.Substring(7)
                if ($o.StartsWith($sha) -or $sha.StartsWith($o)) { return $true }
            }
        }
    }
    return $false
}

function ConvertFrom-GitDate([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim() -replace '\s+\([A-Z]{2,5}\)$', ''
    # RFC 2822 numeric offset "+0530" -> "+05:30"
    $v2 = $v -replace '([+-])(\d{2})(\d{2})$', '$1$2:$3'
    $fmts = @('ddd, d MMM yyyy HH:mm:ss zzz', 'd MMM yyyy HH:mm:ss zzz', 'yyyy-MM-ddTHH:mm:sszzz', 'yyyy-MM-dd HH:mm:ss zzz')
    foreach ($f in $fmts) {
        $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParseExact($v2, $f, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) { return $dto.Date }
    }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($v2, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) { return $dto.Date }
    return $null
}

function Get-Prop($Obj, [string[]]$Names) {
    foreach ($n in $Names) {
        if ($Obj.PSObject.Properties[$n] -and -not [string]::IsNullOrWhiteSpace([string]$Obj.$n)) { return [string]$Obj.$n }
    }
    return $null
}

function ConvertTo-FormulaString([string]$s) { return ([string]$s).Replace('"', '""') }

# commits.json entry -> tracker row model.
function ConvertTo-TrackerRow($Commit, [string]$Organization, [string]$Project, [string]$Repository, [hashtable]$FullShas) {
    $sha = Get-Prop $Commit @('CommitID', 'CommitHash', 'Hash')
    $subject = Get-Prop $Commit @('Subject', 'Title')
    $author = Get-Prop $Commit @('Author', 'Owner')
    $desc = Get-Prop $Commit @('Comments', 'Description')
    $date = ConvertFrom-GitDate (Get-Prop $Commit @('Date'))
    $repoBase = "https://dev.azure.com/$Organization/$Project/_git/$Repository"
    if ($subject -match '^\s*Merged PR (\d+):\s*(.*)$') {
        $prId = $Matches[1]; $title = $Matches[2].Trim()
        $key = "pr:$prId"; $url = "$repoBase/pullrequest/$prId"; $text = "Pull Request ${prId}: $title"
    } else {
        $full = if ($FullShas -and $sha -and $FullShas.ContainsKey($sha)) { $FullShas[$sha] } else { $sha }
        $short = if ($sha -and $sha.Length -gt 9) { $sha.Substring(0, 9) } else { $sha }
        $key = "commit:$(([string]$sha).ToLowerInvariant())"; $url = "$repoBase/commit/$full"; $text = "Commit ${short}: $subject"
    }
    if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
    if ($desc) { $desc = (($desc -replace '\r?\n', ' ') -replace '\s+', ' ').Trim() }
    return [pscustomobject]@{
        key = $key; sha = $sha; date = $date; author = $author; linkUrl = $url; linkText = $text; description = $desc
    }
}

# Formula/value for one cell of a new row, by column source.
function Get-CellFormula($Row, [string]$Source) {
    switch ($Source) {
        'date'        { if ($Row.date) { return ([datetime]$Row.date).ToOADate() } else { return '' } }
        'author'      { return [string]$Row.author }
        'link'        { return "=HYPERLINK(""$(ConvertTo-FormulaString $Row.linkUrl)"",""$(ConvertTo-FormulaString $Row.linkText)"")" }
        'linkText'    { return [string]$Row.linkText }
        'description' { return [string]$Row.description }
        'commitId'    { return [string]$Row.sha }
        default       { return '' }
    }
}

function Get-CellNumberFormat([string]$Source, [string]$DateFormat) {
    switch ($Source) {
        'date' { return $DateFormat }
        'link' { return 'General' }
        default { return '@' }
    }
}
