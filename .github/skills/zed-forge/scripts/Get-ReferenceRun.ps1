<#
.SYNOPSIS
    Return the GOLDEN reference-run parameters ZedForge compares against — from
    the cached requirements/reference-runs.json, or fetched live from ADO.

.DESCRIPTION
    The reference runs are known-good successful prod/canary builds. Their full
    templateParameters are cached in requirements/reference-runs.json. This
    script returns them for a scope (prod/canary) so the agent (Phase 6) or a
    human can compare a current run's parameter SYNTAX against the golden shape.
    Use -Refresh to re-fetch every reference build from ADO and rewrite the cache
    (e.g., when the reference set is updated).

.PARAMETER Scope     'prod' | 'canary' | 'all' (default).
.PARAMETER BuildId   Fetch one specific build live from ADO (ignores the cache).
.PARAMETER Refresh   Re-fetch ALL cached reference builds from ADO, rewrite the cache.
.PARAMETER ReferencePath  Override. Default <skill>/requirements/reference-runs.json.
.OUTPUTS  Reference run object(s): { buildId, definitionId, name, buildNumber, sourceBranch, templateParameters }.
#>
[CmdletBinding()]
param(
    [ValidateSet('prod', 'canary', 'all')][string]$Scope = 'all',
    [int]$BuildId,
    [switch]$Refresh,
    [string]$ReferencePath
)

$ErrorActionPreference = 'Stop'
if (-not $ReferencePath) { $ReferencePath = Join-Path $PSScriptRoot '..\requirements\reference-runs.json' }
$adoResource = '499b84ac-1321-427f-aa17-267ca6975798'
$org = 'msazure'; $project = 'One'

function Get-AdoBuild([int]$id) {
    $tok = az account get-access-token --resource $adoResource --query accessToken -o tsv 2>$null
    if (-not $tok) { throw "No ADO token. Run 'az login --tenant microsoft.com'." }
    $b = Invoke-RestMethod -Uri "https://dev.azure.com/$org/$project/_apis/build/builds/$id`?api-version=7.0" -Headers @{ Authorization = "Bearer $tok" }
    [ordered]@{ buildId = $id; definitionId = $b.definition.id; name = $b.definition.name; buildNumber = $b.buildNumber; sourceBranch = $b.sourceBranch; templateParameters = $b.templateParameters }
}

# Live fetch of a single build
if ($BuildId) { return [pscustomobject](Get-AdoBuild $BuildId) }

if (-not (Test-Path $ReferencePath)) { throw "Reference cache not found: $ReferencePath. Run with -Refresh to build it (requires known build ids in the cache) or add reference-runs.json." }
$cache = Get-Content $ReferencePath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Refresh) {
    foreach ($sc in 'prod', 'canary') {
        $updated = @()
        foreach ($e in @($cache.$sc)) { $updated += [pscustomobject](Get-AdoBuild ([int]$e.buildId)) }
        $cache.$sc = $updated
    }
    $cache.fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
    ($cache | ConvertTo-Json -Depth 12) | Set-Content $ReferencePath -Encoding UTF8
    Write-Host "Refreshed reference cache: $ReferencePath"
}

switch ($Scope) {
    'prod' { return @($cache.prod) }
    'canary' { return @($cache.canary) }
    default { return $cache }
}
