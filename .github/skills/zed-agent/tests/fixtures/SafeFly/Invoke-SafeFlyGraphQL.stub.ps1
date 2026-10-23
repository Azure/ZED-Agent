# Test stub for scripts/SafeFly/Invoke-SafeFlyGraphQL.ps1 (SafeFly.Tests.ps1 copies it into a
# staged scripts/SafeFly folder). Logs every query to calls.log, answers the read queries from
# fixture.json, and throws on any mutation so a DryRun that tries to submit fails the test.
param([string]$Query, $Variables = @{}, [string]$ServiceConfigPath)
$fx = Get-Content (Join-Path $PSScriptRoot 'fixture.json') -Raw | ConvertFrom-Json
Add-Content (Join-Path $PSScriptRoot 'calls.log') -Value ($Query -replace '\s+', ' ')
if ($Query -match 'mutation') { throw "STUB: mutation called: $Query" }
if ($Query -match 'getRegionsWithActiveCCOACoverage') {
    return [pscustomobject]@{ getRegionsWithActiveCCOACoverage = [pscustomobject]@{ regions = @($fx.regions) } }
}
if ($Query -match 'regionGroups') {
    return [pscustomobject]@{ regionGroups = @($fx.regionGroups) }
}
if ($Query -match 'tags\(') {
    # Server semantics: tags(name:) is a case-insensitive CONTAINS match.
    $n = "$($Variables.name)"
    return [pscustomobject]@{ tags = @($fx.tags | Where-Object { $_.name -like "*$n*" }) }
}
if ($Query -match 'requests\(') {
    $rows = @($fx.requests | Where-Object { $_.id -eq $Variables.f.objectId.equalTo })
    return [pscustomobject]@{ requests = [pscustomobject]@{ totalCount = $rows.Count; data = $rows } }
}
throw "STUB: unexpected query $Query"
