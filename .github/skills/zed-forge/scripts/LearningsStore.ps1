<#
.SYNOPSIS
    Shared read/render helpers for the FREEFORM ZED lessons-learned backlog
    (learnings.md). Dot-sourced by Add-Learning.ps1 and Get-Learnings.ps1.

.DESCRIPTION
    learnings.md is the real ZED "lessons learned" file — human/agent-authored
    freeform entries in several shapes:
      - "**Timestamp**: …" blocks with **Step/Command** / **Symptom** / **Root cause** / **Fix** / **Proposed fix**
      - "## <date> — <title>" or "### <n>. <title>" blocks with "- **Field:** …" bullets
    Entries are separated by headings (## / ###) or a **Timestamp** line (--- rules
    are ignored). Each entry gets a STABLE key = short SHA1 of its normalized text
    (ZedForge status markers stripped, so marking implemented never changes the key).

    Implemented-status is tracked in forge-state.json → implementedLearnings[]:
      { key, title, iteration, appliedTo[], at }
    (Kept OUT of learnings.md so the human file stays clean and its keys stable.)
#>

function Split-LearningsEntries {
    param([Parameter(Mandatory)][string]$Path)
    $entries = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $Path)) { return $entries }
    $cur = $null
    foreach ($ln in (Get-Content $Path -Encoding UTF8)) {
        if ($ln -match '^\s*---\s*$') { continue }                       # horizontal rule → skip
        $isBoundary = ($ln -match '^#{2,3}\s+\S') -or ($ln -match '^\*\*Timestamp\*\*')
        if ($isBoundary) {
            if ($null -ne $cur) { $t = ($cur -join "`n").Trim(); if ($t) { $entries.Add($t) } }
            $cur = New-Object System.Collections.Generic.List[string]
            $cur.Add($ln)
        }
        elseif ($null -ne $cur) { $cur.Add($ln) }                        # (pre-boundary preamble/title ignored)
    }
    if ($null -ne $cur) { $t = ($cur -join "`n").Trim(); if ($t) { $entries.Add($t) } }

    # Drop entries that are just a heading with no body (e.g., a section header above nested learnings).
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
        $body = @(@($e -split "`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })
        if ($body.Count -ge 1) { $result.Add($e) }
    }
    return $result
}

function Get-LearningKey {
    param([Parameter(Mandatory)][string]$Text)
    $norm = (@($Text -split "`n" | Where-Object { $_ -notmatch '^\s*>\s*\*\*ZedForge' }) -join "`n").Trim()
    $norm = ($norm -replace '\s+', ' ')
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    return (-join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') }))   # 12 hex chars
}

function Get-LearningTitle {
    param([Parameter(Mandatory)][string]$Text)
    $lines = @($Text -split "`n")
    $first = $lines[0].Trim()
    if ($first -match '^#{2,3}\s+(.*)$') { return $Matches[1].Trim() }
    if ($first -match '^\*\*Timestamp\*\*\s*:?\s*(.*)$') {
        $ts = $Matches[1].Trim()
        foreach ($l in $lines) { if ($l -match '^\*\*Step/Command\*\*\s*:?\s*(.*)$') { return "$($Matches[1].Trim())  ($ts)" } }
        return "Learning ($ts)"
    }
    return $first.Substring(0, [Math]::Min(90, $first.Length))
}

function Get-ImplementedLearnings {
    param([Parameter(Mandatory)][string]$StatePath)
    if (-not (Test-Path $StatePath)) { return @() }
    try { $s = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    if ($s.PSObject.Properties['implementedLearnings']) { return @($s.implementedLearnings) }
    return @()
}

function Set-ImplementedLearning {
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][hashtable]$Record)
    $s = $null
    if (Test-Path $StatePath) { try { $s = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null } }
    if (-not $s) { $s = [pscustomobject]@{ status = 'running'; implementedLearnings = @() } }
    if (-not $s.PSObject.Properties['implementedLearnings']) { Add-Member -InputObject $s -MemberType NoteProperty -Name implementedLearnings -Value @() -Force }
    $list = @($s.implementedLearnings | Where-Object { $_.key -ne $Record.key })   # replace existing
    $list += [pscustomobject]$Record
    $s.implementedLearnings = $list
    if ($s.PSObject.Properties['lastUpdated']) { $s.lastUpdated = (Get-Date).ToUniversalTime().ToString('o') }
    $dir = Split-Path $StatePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($s | ConvertTo-Json -Depth 20) | Set-Content $StatePath -Encoding UTF8
}

function Read-Learnings {
    param([Parameter(Mandatory)][string]$Path, [string]$StatePath)
    $impl = @{}
    if ($StatePath) { foreach ($r in (Get-ImplementedLearnings -StatePath $StatePath)) { $impl[$r.key] = $r } }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($txt in (Split-LearningsEntries -Path $Path)) {
        $key = Get-LearningKey -Text $txt
        $inline = ($txt -match '(?im)^\s*>\s*\*\*ZedForge')
        $rec = $impl[$key]
        $status = if ($rec -or $inline) { 'implemented' } else { 'pending' }
        $out.Add([pscustomobject]@{
            key       = $key
            title     = (Get-LearningTitle -Text $txt)
            status    = $status
            iteration = if ($rec) { $rec.iteration } else { $null }
            appliedTo = if ($rec) { @($rec.appliedTo) } else { @() }
            text      = $txt
        })
    }
    return $out
}
