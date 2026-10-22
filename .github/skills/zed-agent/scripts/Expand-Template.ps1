function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Variables,
        # When set, leftover {{placeholder}} tokens after substitution throw an error
        # instead of being silently sent to Teams/email. Default ON because a
        # half-rendered message is almost always a bug, not intentional.
        [bool]$StrictPlaceholders = $true,
        # Source of the {{releaseLabel}} default (service.releaseLabel, else 'BDP').
        [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\service-config.json')
    )
    $content = (Get-Content -Path $TemplatePath -Raw -Encoding UTF8).TrimEnd("`r`n")
    # {{releaseLabel}} — the name in release message titles ("<label> Release Branch Cut Reminder").
    # Defaults to service-config.json → service.releaseLabel, else 'BDP' (the text these templates
    # always carried), so existing services render exactly as before; callers need not pass it.
    if ($content -match '\{\{[#/]?releaseLabel\}\}' -and -not $Variables.ContainsKey('releaseLabel')) {
        $label = 'BDP'
        try {
            if ($ServiceConfigPath -and (Test-Path -LiteralPath $ServiceConfigPath)) {
                $svc = (Get-Content -LiteralPath $ServiceConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).service
                if ($svc -and $svc.PSObject.Properties['releaseLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$svc.releaseLabel)) { $label = [string]$svc.releaseLabel }
            }
        } catch { }
        $Variables = $Variables.Clone(); $Variables['releaseLabel'] = $label
    }
    # Handle conditional sections: {{#key}}...{{/key}}
    foreach ($key in $Variables.Keys) {
        $val = $Variables[$key]
        if ($val -is [bool] -or $val -is [string]) {
            $truthy = if ($val -is [bool]) { $val } else { [string]::IsNullOrEmpty($val) -eq $false }
            if ($truthy) {
                $content = $content -replace "(?s)\{\{#$key\}\}(.*?)\{\{/$key\}\}", '$1'
            } else {
                $content = $content -replace "(?s)\{\{#$key\}\}(.*?)\{\{/$key\}\}", ''
            }
        }
    }
    # Remove unmatched conditional blocks (undefined variables)
    $content = $content -replace '(?s)\{\{#\w+\}\}.*?\{\{/\w+\}\}', ''
    # Replace {{variable}} placeholders with values from $Variables.
    # Escape '$' in replacement to prevent -replace from interpreting $1/$&/etc. as regex backreferences.
    foreach ($key in $Variables.Keys) {
        $replacement = ([string]$Variables[$key]) -replace '\$', '$$$$'
        $content = $content -replace "\{\{$key\}\}", $replacement
    }
    if ($StrictPlaceholders) {
        $leftover = [regex]::Matches($content, '\{\{[^{}]+\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique
        if ($leftover) {
            throw "Expand-Template: template '$TemplatePath' has unsubstituted placeholders: $($leftover -join ', '). Add these keys to -Variables or pass -StrictPlaceholders:`$false to allow."
        }
    }
    return $content
}
