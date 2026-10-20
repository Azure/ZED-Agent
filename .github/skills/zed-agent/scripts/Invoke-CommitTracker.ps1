<#
.SYNOPSIS
    Shared commit tracker workbook (one sheet per release) for Step 4 / Step 13, used when
    service-config.json → commitExcel.mode == "tracker" (e.g. BCM "BCM Release Commits Tracker.xlsx").

.DESCRIPTION
    Edits the live workbook in place through the Microsoft Graph Excel API (with a persistent
    workbook session), so co-authors' edits in other sheets are never overwritten — the file is
    never downloaded and re-uploaded.

    Actions
      Publish  Step 4 Phase A. Ensures the release sheet (commitExcel.sheetNameTemplate, e.g.
               BCM{{YYMM}} → BCM2611) exists — creates it at the end with the configured header row
               and styling — then APPENDS one row per commit in -CommitsJsonPath that is not already
               on the sheet (matched by PR id / commit sha in the link column). Existing rows and
               cells are never modified, so re-runs, `rebuild` and late cherry-picks only add rows.
               If the sheet already exists (e.g. created by hand) it is adopted when its header row
               contains every configured column; otherwise Publish fails without writing.
      Poll     Step 4 Phase B / Step 13 barrier. Fill % = rows (with a link) whose required columns
               are all non-empty / rows with a link.
      Read     Step 13. Returns every data row keyed by header.

    Column model (commitExcel.tracker.columns, in sheet order):
      { "header": "<text>", "source": "date|author|link|linkText|description|commitId" }  ZED-filled
      { "header": "<text>", "required": true }                                           team-filled
    'link' writes =HYPERLINK(<PR or commit URL>, "Pull Request <id>: <title>" | "Commit <sha>: <subject>").

.OUTPUTS
    PSCustomObject: Success, Action, Status, SheetName, DriveId, ItemId, WorkbookUrl, Created,
    Appended, AlreadyPresent, TotalRows, Filled, Pct, Missing[], Rows[], Error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Publish', 'Poll', 'Read')][string]$Action,
    [Parameter(Mandatory)][string]$ReleaseId,
    [string]$CommitsJsonPath,
    [string]$SheetName,
    [string]$TrackerUrl,
    [string]$DriveId,
    [string]$ItemId,
    [string]$ServiceConfigPath,
    [string]$ReleaseFile,
    [string]$RepoPath,
    [string]$AccessToken,
    [int]$MaxAttempts = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\CommitTrackerLib.ps1')

$out = [pscustomobject]@{
    Success = $false; Action = $Action; Status = $null; SheetName = $null
    DriveId = $null; ItemId = $null; WorkbookUrl = $null
    Created = $false; Appended = 0; AlreadyPresent = 0
    TotalRows = 0; Filled = 0; Pct = 0; Missing = @(); Rows = @(); Error = $null
}
$script:SessionId = $null

function Get-GraphToken {
    if ($script:AccessToken) { return $script:AccessToken }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $t = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv 2>$null }
    finally { $ErrorActionPreference = $prev }
    if (-not $t) { throw "Failed to acquire a Microsoft Graph token. Run 'az login --tenant microsoft.com'." }
    $script:AccessToken = $t
    return $t
}

function Invoke-Graph([string]$Method, [string]$Path, $Body) {
    $uri = if ($Path -like 'https://*') { $Path } else { "https://graph.microsoft.com/v1.0$Path" }
    for ($attempt = 1; ; $attempt++) {
        $headers = @{ Authorization = "Bearer $(Get-GraphToken)" }
        if ($script:SessionId) { $headers['workbook-session-id'] = $script:SessionId }
        $p = @{ Uri = $uri; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
        if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $p.ContentType = 'application/json' }
        try {
            return Invoke-RestMethod @p
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            $retryable = $code -in @(409, 423, 429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -ge $MaxAttempts) {
                $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { '' }
                throw "Graph $Method $Path failed: $($_.Exception.Message)$detail"
            }
            $wait = [math]::Min(30, [math]::Pow(2, $attempt))
            try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds; if ($ra) { $wait = [math]::Min(60, $ra) } } catch { }
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-SheetPath([string]$Name) {
    return "$($script:WbPath)/worksheets('$([uri]::EscapeDataString($Name.Replace("'", "''")))')"
}

function Get-SheetGrid([string]$Name) {
    # Returns @{ exists; lastRow; values (2D, rows 1..lastRow) }
    $sheets = Invoke-Graph GET "$($script:WbPath)/worksheets?`$select=name"
    $exists = @($sheets.value | Where-Object { $_.name -eq $Name }).Count -gt 0
    if (-not $exists) { return @{ exists = $false; lastRow = 0; values = @() } }
    $used = Invoke-Graph GET "$(Get-SheetPath $Name)/usedRange(valuesOnly=true)?`$select=address"
    $addr = ([string]$used.address).Split('!')[-1]
    if ($addr -notmatch ':?([A-Z]+)(\d+)$') { return @{ exists = $true; lastRow = 0; values = @() } }
    $lastCol = $Matches[1]; $lastRow = [int]$Matches[2]
    $grid = Invoke-Graph GET "$(Get-SheetPath $Name)/range(address='A1:$lastCol$lastRow')?`$select=text"
    # A single empty A1 means an empty sheet
    $vals = @($grid.text)
    if ($lastRow -eq 1 -and @($vals[0] | Where-Object { "$_" -ne '' }).Count -eq 0) { $lastRow = 0; $vals = @() }
    return @{ exists = $true; lastRow = $lastRow; values = $vals }
}

try {
    # ---- config ----
    if (-not $ServiceConfigPath) { $ServiceConfigPath = Join-Path $PSScriptRoot '..\service-config.json' }
    $svc = Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ce = $svc.commitExcel
    if (-not $ce -or [string]$ce.mode -ne 'tracker' -or -not $ce.tracker) {
        throw "service-config.json → commitExcel.mode is not 'tracker' (or commitExcel.tracker is missing)."
    }
    $tr = $ce.tracker
    $columns = @($tr.columns)
    if ($columns.Count -eq 0) { throw "commitExcel.tracker.columns is empty." }
    if (@($columns | Where-Object { $_.source -eq 'link' -or $_.source -eq 'linkText' }).Count -ne 1) {
        throw "commitExcel.tracker.columns needs exactly one column with source 'link' (or 'linkText') — it identifies each row."
    }
    $linkKey = ConvertTo-HeaderKey (@($columns | Where-Object { $_.source -in @('link', 'linkText') })[0].header)
    $dateFormat = if ($tr.PSObject.Properties['dateFormat'] -and $tr.dateFormat) { [string]$tr.dateFormat } else { 'dd-mm-yyyy' }

    if (-not $SheetName) {
        $tmpl = if ($ce.sheetNameTemplate) { [string]$ce.sheetNameTemplate } else { '{{YYMM}}' }
        $relForName = if ($ReleaseFile -and (Test-Path -LiteralPath $ReleaseFile)) { Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        $SheetName = Expand-SheetName $tmpl $ReleaseId $relForName
    }
    $bad = Test-SheetName $SheetName
    if ($bad) { throw $bad }
    $out.SheetName = $SheetName

    # ---- test mode never writes to the shared tracker ----
    if ($Action -eq 'Publish' -and $ReleaseFile -and (Test-Path -LiteralPath $ReleaseFile)) {
        $rel = Get-Content -LiteralPath $ReleaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rel.PSObject.Properties['testMode'] -and $rel.testMode -eq $true) {
            $out.Status = 'skipped-test-mode'; $out.Success = $true
            return $out
        }
    }

    # ---- locate workbook ----
    if (-not $TrackerUrl) { $TrackerUrl = [string]$tr.url }
    if (-not $DriveId -or -not $ItemId) {
        if (-not $TrackerUrl) { throw "commitExcel.tracker.url is empty." }
        $enc = 'u!' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($TrackerUrl)).TrimEnd('=').Replace('/', '_').Replace('+', '-')
        $item = Invoke-Graph GET "/shares/$enc/driveItem?`$select=id,name,webUrl,parentReference"
        $DriveId = $item.parentReference.driveId; $ItemId = $item.id
    }
    $out.DriveId = $DriveId; $out.ItemId = $ItemId
    $out.WorkbookUrl = if ($TrackerUrl) { $TrackerUrl } else { $null }
    $script:WbPath = "/drives/$DriveId/items/$ItemId/workbook"

    switch ($Action) {
        'Publish' {
            if (-not $CommitsJsonPath -or -not (Test-Path -LiteralPath $CommitsJsonPath)) { throw "-CommitsJsonPath is required for Publish." }
            $commits = @(Get-Content -LiteralPath $CommitsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            $exclude = @($ce.excludeAuthors | Where-Object { $_ })
            $commits = @($commits | Where-Object { $exclude -notcontains (Get-Prop $_ @('Author', 'Owner')) })

            $fullShas = @{}
            if (-not $RepoPath) { $RepoPath = (Get-Location).Path }
            foreach ($c in $commits) {
                $sha = Get-Prop $c @('CommitID', 'CommitHash', 'Hash')
                if ($sha -and $sha.Length -lt 40) {
                    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    try { $full = git -C $RepoPath rev-parse --verify --quiet "$sha^{commit}" 2>$null } finally { $ErrorActionPreference = $prev }
                    if ($LASTEXITCODE -eq 0 -and $full) { $fullShas[$sha] = ([string]$full).Trim() }
                }
            }
            $org = $svc.ado.organization; $proj = $svc.ado.project; $repo = $svc.ado.repository
            $rows = New-Object System.Collections.Generic.List[object]
            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($c in $commits) {
                $r = ConvertTo-TrackerRow $c $org $proj $repo $fullShas
                if ($seen.Add($r.key)) { $rows.Add($r) }
            }
            $rows = @($rows | Sort-Object @{ Expression = { if ($_.date) { $_.date } else { [datetime]::MaxValue } } }, linkText)

            $grid = Get-SheetGrid $SheetName
            $headers = @($columns | ForEach-Object { [string]$_.header })
            $script:SessionId = (Invoke-Graph POST "$($script:WbPath)/createSession" @{ persistChanges = $true }).id

            if (-not $grid.exists -or $grid.lastRow -eq 0) {
                if (-not $grid.exists) {
                    $null = Invoke-Graph POST "$($script:WbPath)/worksheets" @{ name = $SheetName }
                    $out.Created = $true
                }
                $lastCol = Get-ColumnLetter ($headers.Count - 1)
                $hdrRange = "$(Get-SheetPath $SheetName)/range(address='A1:${lastCol}1')"
                $null = Invoke-Graph PATCH $hdrRange @{ values = @(, $headers) }
                $hs = $tr.headerStyle
                if ($hs) {
                    $fmt = @{}; if ($null -ne $hs.wrapText) { $fmt.wrapText = [bool]$hs.wrapText }
                    if ($fmt.Count) { $null = Invoke-Graph PATCH "$hdrRange/format" $fmt }
                    if ($hs.fill) { $null = Invoke-Graph PATCH "$hdrRange/format/fill" @{ color = [string]$hs.fill } }
                    $font = @{}; if ($null -ne $hs.bold) { $font.bold = [bool]$hs.bold }; if ($hs.fontColor) { $font.color = [string]$hs.fontColor }
                    if ($font.Count) { $null = Invoke-Graph PATCH "$hdrRange/format/font" $font }
                }
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $w = $columns[$i].PSObject.Properties['width']
                    if ($w -and $w.Value) {
                        $L = Get-ColumnLetter $i
                        $null = Invoke-Graph PATCH "$(Get-SheetPath $SheetName)/range(address='${L}:${L}')/format" @{ columnWidth = [double]$w.Value }
                    }
                }
                $colIndex = @{}; for ($i = 0; $i -lt $columns.Count; $i++) { $colIndex[(ConvertTo-HeaderKey $columns[$i].header)] = $i }
                $existing = New-Object 'System.Collections.Generic.HashSet[string]'
                $nextRow = 2
            } else {
                $hm = Get-HeaderMap @($grid.values[0]) $columns
                if ($hm.missing.Count -gt 0) {
                    throw "Sheet '$SheetName' already exists but its header row (row 1) is missing: $($hm.missing -join ', '). Nothing was written — fix the header or delete the sheet, then retry."
                }
                $colIndex = $hm.map
                $existing = New-Object 'System.Collections.Generic.HashSet[string]'
                $li = $colIndex[$linkKey]
                for ($r = 1; $r -lt $grid.values.Count; $r++) {
                    $k = Get-RowKey ([string]$grid.values[$r][$li])
                    if ($k) { [void]$existing.Add($k) }
                }
                $nextRow = $grid.lastRow + 1
            }

            $toAdd = @($rows | Where-Object { -not (Test-KeyPresent $_.key $existing) })
            $out.AlreadyPresent = $rows.Count - $toAdd.Count
            if ($toAdd.Count -gt 0) {
                $width = ([int](@($colIndex.Values) | Measure-Object -Maximum).Maximum) + 1
                $formulas = New-Object System.Collections.Generic.List[object]
                $formats = New-Object System.Collections.Generic.List[object]
                foreach ($row in $toAdd) {
                    $f = New-Object object[] $width; $nf = New-Object object[] $width
                    for ($i = 0; $i -lt $width; $i++) { $f[$i] = ''; $nf[$i] = 'General' }
                    foreach ($c in $columns) {
                        $i = $colIndex[(ConvertTo-HeaderKey $c.header)]
                        $src = if ($c.PSObject.Properties['source']) { [string]$c.source } else { '' }
                        $f[$i] = Get-CellFormula $row $src
                        $nf[$i] = Get-CellNumberFormat $src $dateFormat
                    }
                    $formulas.Add($f); $formats.Add($nf)
                }
                $lastCol = Get-ColumnLetter ($width - 1)
                $endRow = $nextRow + $toAdd.Count - 1
                $rng = "$(Get-SheetPath $SheetName)/range(address='A${nextRow}:$lastCol$endRow')"
                # number formats first: text columns become '@' so values starting with = + - @ stay text
                $null = Invoke-Graph PATCH $rng @{ numberFormat = $formats.ToArray() }
                $null = Invoke-Graph PATCH $rng @{ formulas = $formulas.ToArray() }
            }
            $out.Appended = $toAdd.Count
            $out.TotalRows = $existing.Count + $toAdd.Count
            $out.Status = if ($out.Created) { 'created' } elseif ($toAdd.Count -gt 0) { 'appended' } else { 'up-to-date' }
        }
        { $_ -in @('Poll', 'Read') } {
            $grid = Get-SheetGrid $SheetName
            if (-not $grid.exists) { throw "Sheet '$SheetName' does not exist in the tracker workbook." }
            if ($grid.lastRow -lt 1) { throw "Sheet '$SheetName' is empty." }
            $header = @($grid.values[0])
            $hm = Get-HeaderMap $header $columns
            if ($hm.missing.Count -gt 0) { throw "Sheet '$SheetName' header row is missing: $($hm.missing -join ', ')." }
            $li = $hm.map[$linkKey]
            $required = @($columns | Where-Object { $_.PSObject.Properties['required'] -and $_.required -eq $true })
            $total = 0; $filled = 0
            $missing = New-Object System.Collections.Generic.List[object]
            $rowsOut = New-Object System.Collections.Generic.List[object]
            for ($r = 1; $r -lt $grid.values.Count; $r++) {
                $vals = @($grid.values[$r])
                $link = if ($li -lt $vals.Count) { ([string]$vals[$li]).Trim() } else { '' }
                if (-not $link) { continue }
                $total++
                $gaps = @($required | Where-Object {
                        $i = $hm.map[(ConvertTo-HeaderKey $_.header)]
                        -not ($i -lt $vals.Count -and ([string]$vals[$i]).Trim())
                    } | ForEach-Object { [string]$_.header })
                if ($gaps.Count -eq 0) { $filled++ } elseif ($missing.Count -lt 50) {
                    $missing.Add([pscustomobject]@{ row = $r + 1; link = $link; missingColumns = $gaps })
                }
                if ($Action -eq 'Read') {
                    $o = [ordered]@{ row = $r + 1 }
                    for ($i = 0; $i -lt $header.Count; $i++) {
                        $h = [string]$header[$i]; if (-not $h) { continue }
                        $o[$h] = if ($i -lt $vals.Count) { [string]$vals[$i] } else { '' }
                    }
                    $rowsOut.Add([pscustomobject]$o)
                }
            }
            $out.TotalRows = $total; $out.Filled = $filled
            $out.Pct = if ($total -eq 0) { 0 } elseif ($filled -eq $total) { 100 } else { [int][math]::Floor(100.0 * $filled / $total) }
            $out.Missing = $missing.ToArray()
            $out.Rows = $rowsOut.ToArray()
            $out.Status = if ($total -gt 0 -and $filled -eq $total) { 'complete' } else { 'incomplete' }
        }
    }
    $out.Success = $true
} catch {
    $out.Error = $_.Exception.Message
    if ($Action -eq 'Publish') { throw }
} finally {
    if ($script:SessionId) {
        try { $null = Invoke-Graph POST "$($script:WbPath)/closeSession" $null } catch { }
        $script:SessionId = $null
    }
}

return $out
