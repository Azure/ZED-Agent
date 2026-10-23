function New-CommitExcel {
    param(
        [Parameter(Mandatory)][string]$CommitsJsonPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$SheetName = 'Commits',
        [string[]]$AutoColumns = @('CommitHash','Owner','Date','Title','Comments'),
        [string[]]$ManualColumns = @('Impact (Low/Medium/High)','Validations (UnitTest/ CanaryTesting/ BVTs etc)','Rollback Friendly (Yes / No)'),
        [hashtable]$FieldMap = @{ CommitHash='CommitID'; Owner='Author'; Title='Subject' },
        [string]$TableStyle = 'Medium2',
        [int]$MaxCommentsLength = 200
    )
    $commits = Get-Content $CommitsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($commits | ForEach-Object {
        $row = [ordered]@{}
        foreach ($col in $AutoColumns) {
            $srcProp = if ($FieldMap.ContainsKey($col)) { $FieldMap[$col] } else { $col -replace '\s','' }
            $val = if ($_ | Get-Member -Name $srcProp -ErrorAction SilentlyContinue) { $_.$srcProp } else { $null }
            # Truncate Comments if it exceeds max length
            if ($col -eq 'Comments' -and $val) {
                $val = ($val -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
                if ($val.Length -gt $MaxCommentsLength) {
                    $val = $val.Substring(0, $MaxCommentsLength - 3) + '...'
                }
                if (-not $val) { $val = $null }
            }
            $row[$col] = $val
        }
        foreach ($col in $ManualColumns) {
            $srcProp = if ($FieldMap.ContainsKey($col)) { $FieldMap[$col] } else { $col -replace '\s','' }
            $row[$col] = if ($_ | Get-Member -Name $srcProp -ErrorAction SilentlyContinue) { $_.$srcProp } else { $null }
        }
        [PSCustomObject]$row
    })

    # Export with Excel Table formatting (TableStyleMedium2 = blue banded rows)
    $rows | Export-Excel -Path $OutputPath -WorksheetName $SheetName -AutoSize -TableName $SheetName -TableStyle $TableStyle

    return @{ success = $true; path = $OutputPath; rowCount = $rows.Count }
}
