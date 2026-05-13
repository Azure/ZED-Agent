function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Variables,
        # When set, leftover {{placeholder}} tokens after substitution throw an error
        # instead of being silently sent to Teams/email. Default ON because a
        # half-rendered message is almost always a bug, not intentional.
        [bool]$StrictPlaceholders = $true
    )
    $content = (Get-Content -Path $TemplatePath -Raw -Encoding UTF8).TrimEnd("`r`n")
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
