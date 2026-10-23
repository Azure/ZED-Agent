<#
.SYNOPSIS
    Learns a parameter model for one or more catalog pipelines from prior runs
    the release owner supplied, and persists it under
    pipeline-catalog.json -> <scope>.<key>._learnedFrom.

.DESCRIPTION
    setup-service Phase 4.3 asks the release owner for the run URLs of ONE real
    release. That is all. ZED then:

      1. Resolves each run to its owning pipeline definition itself, so the
         owner never has to say which run belongs to which pipeline.
      2. Matches each definition id against the catalog, so a run for a
         pipeline ZED does not know about is reported rather than silently
         dropped.
      3. Builds a per-parameter model (declared default, value shape, container,
         stability, confidence) and writes it under `_learnedFrom`.
      4. Reports which catalog pipelines are still uncovered, so the caller can
         ask for more runs instead of guessing.

    Confidence is deliberately conservative: a value is only trustworthy when
    at least two INDEPENDENT releases agree on it. Run this a second time with
    -Merge and an older release's runs to clear `lowConfidence`.

    Runs ZED authored itself are excluded upstream by Read-PriorRun.ps1.

.PARAMETER CatalogPath
    Path to pipeline-catalog.json.

.PARAMETER RunIds
    Build/run ids from a real release.

.PARAMETER RunUrls
    ADO run URLs; the build id is extracted from each. Combined with -RunIds.

.PARAMETER ReleaseGroup
    Tag identifying the release these runs belong to. Two runs sharing a tag
    count as ONE independent observation. Defaults to each run's source branch.

.PARAMETER KnownDeficientRunIds
    Runs the release owner knows produced WRONG values - e.g. a release where a
    bug left part of the fleet out. They still count as evidence of the
    parameter SURFACE and its shape, but never supply a value, so their mistake
    cannot be inherited by the next release. Merged with any ids already
    recorded under `_learnedFrom.knownDeficientRuns` when -Merge is used.

.PARAMETER Merge
    Fold these runs into whatever `_learnedFrom.runs` already holds instead of
    replacing it. This is how a second release raises confidence. Previously
    recorded run ids are re-read from ADO so the merged model is rebuilt from
    complete run records rather than from ids alone.

.PARAMETER RepoRoot
    Deployment repo root, used to locate the self-authored run ledger.

.PARAMETER NoWrite
    Compute and report without touching the catalog.

.OUTPUTS
    PSCustomObject { mapped[], unmapped[], uncovered[], catalogPath, wrote }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [int[]]$RunIds = @(),
    [string[]]$RunUrls = @(),
    [string]$ReleaseGroup,
    [int[]]$KnownDeficientRunIds = @(),
    [switch]$Merge,
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$NoWrite
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\YamlParamModel.ps1')

if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "Pipeline catalog not found: $CatalogPath" }

# -- Normalize the owner's input: URLs and bare ids both land as ints --
$ids = New-Object System.Collections.ArrayList
foreach ($i in @($RunIds)) { if ($i -gt 0 -and -not $ids.Contains([int]$i)) { [void]$ids.Add([int]$i) } }
foreach ($u in @($RunUrls)) {
    if ([string]::IsNullOrWhiteSpace($u)) { continue }
    $m = [regex]::Match($u, '(?:buildId=|/runs/|/results\?buildId=)(\d+)')
    if (-not $m.Success) { $m = [regex]::Match($u, '(\d{5,})') }
    if (-not $m.Success) { throw "Could not extract a run id from '$u'. Paste the full ADO run URL or the numeric id." }
    $v = [int]$m.Groups[1].Value
    if (-not $ids.Contains($v)) { [void]$ids.Add($v) }
}
if ($ids.Count -eq 0) { throw "No run ids supplied. Pass -RunIds and/or -RunUrls." }

# -- Index the catalog by pipeline definition id --
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$entries = New-Object System.Collections.ArrayList
function Add-Entry {
    param([string]$Scope, [string]$Key, $Node)
    if (-not $Node) { return }
    [void]$entries.Add([pscustomobject]@{ scope = $Scope; key = $Key; node = $Node; id = [int]$Node.id })
}
foreach ($prop in $catalog.PSObject.Properties) {
    $val = $prop.Value
    if ($null -eq $val) { continue }
    if ($val.PSObject.Properties['id'] -and $val.id) {
        Add-Entry -Scope $prop.Name -Key $prop.Name -Node $val
        continue
    }
    if ($val -is [System.Management.Automation.PSCustomObject]) {
        foreach ($child in $val.PSObject.Properties) {
            $cv = $child.Value
            if ($cv -is [System.Management.Automation.PSCustomObject] -and $cv.PSObject.Properties['id'] -and $cv.id) {
                Add-Entry -Scope $prop.Name -Key $child.Name -Node $cv
            }
        }
    }
}

$byDefinition = @{}
foreach ($e in $entries) { if ($e.id -gt 0) { $byDefinition[[string]$e.id] = $e } }

# -- Merge: previously learned runs are stored as ids, so re-read them --
# A model built from one run cannot tell a constant from a coincidence. Folding
# the earlier ids back into the fetch is what lets independentReleaseCount rise
# above 1 and lowConfidence clear.
$knownDeficient = New-Object System.Collections.ArrayList
foreach ($i in @($KnownDeficientRunIds)) { if ($i -gt 0 -and -not $knownDeficient.Contains([int]$i)) { [void]$knownDeficient.Add([int]$i) } }

if ($Merge) {
    foreach ($e in $entries) {
        $lf = $e.node.PSObject.Properties['_learnedFrom'] ? $e.node._learnedFrom : $null
        if (-not $lf) { continue }
        foreach ($r in @($lf.runs)) {
            $rid = if ($r -is [int] -or $r -is [long] -or $r -is [string]) { [int]$r } elseif ($r.PSObject.Properties['runId']) { [int]$r.runId } else { 0 }
            if ($rid -gt 0 -and -not $ids.Contains($rid)) { [void]$ids.Add($rid) }
        }
        foreach ($r in @($lf.PSObject.Properties['knownDeficientRuns'] ? $lf.knownDeficientRuns : @())) {
            $rid = [int]$r
            if ($rid -gt 0 -and -not $knownDeficient.Contains($rid)) { [void]$knownDeficient.Add($rid) }
        }
    }
}

# -- Fetch the runs (self-mapping, self-authored runs excluded) --
$readPrior = Join-Path $PSScriptRoot 'Read-PriorRun.ps1'
$priorArgs = @{
    Organization = $Organization
    Project      = $Project
    RunIds       = $ids.ToArray()
    RepoRoot     = $RepoRoot
}
if ($ReleaseGroup) { $priorArgs.ReleaseGroup = $ReleaseGroup }
# Read-PriorRun returns `,@(...)` so that an empty result stays an array; wrapping
# that in another @() would nest it. Bare assignment is the correct call form.
$runs = & $readPrior @priorArgs

# -- Group the runs by the pipeline they actually belong to --
$grouped = @{}
$unmapped = New-Object System.Collections.ArrayList
foreach ($r in $runs) {
    $k = [string]$r.definitionId
    if (-not $byDefinition.ContainsKey($k)) {
        [void]$unmapped.Add([pscustomobject]@{ runId = $r.runId; definitionId = $r.definitionId; runUrl = $r.runUrl })
        continue
    }
    if (-not $grouped.ContainsKey($k)) { $grouped[$k] = New-Object System.Collections.ArrayList }
    [void]$grouped[$k].Add($r)
}

$mapped = New-Object System.Collections.ArrayList
foreach ($k in @($grouped.Keys)) {
    $entry    = $byDefinition[$k]
    $allRuns  = $grouped[$k].ToArray()

    $declared = @()
    $intro = $entry.node.PSObject.Properties['yamlIntrospection'] ? $entry.node.yamlIntrospection : $null
    if ($intro -and $intro.parameters) { $declared = @($intro.parameters) }

    $deficientHere = @(@($knownDeficient) | Where-Object { $rid = $_; @($allRuns | Where-Object { [int]$_.runId -eq [int]$rid }).Count -gt 0 })

    $built = Build-ParameterModel -Runs @($allRuns) -DeclaredParameters $declared -KnownDeficientRunIds $deficientHere

    $learned = [ordered]@{
        updatedAt               = (Get-Date).ToUniversalTime().ToString('o')
        organization            = $Organization
        project                 = $Project
        independentReleaseCount = $built.independentReleaseCount
        runs                    = $built.runs
        knownDeficientRuns      = $built.knownDeficientRuns
        model                   = $built.model
    }
    if (-not $NoWrite) {
        $entry.node | Add-Member -NotePropertyName '_learnedFrom' -NotePropertyValue ([pscustomobject]$learned) -Force
    }

    $lowCount = @($built.model.PSObject.Properties | Where-Object { $_.Value.lowConfidence }).Count
    [void]$mapped.Add([pscustomobject]@{
        scope                   = $entry.scope
        key                     = $entry.key
        definitionId            = $entry.id
        runIds                  = @($allRuns | ForEach-Object { $_.runId })
        independentReleaseCount = $built.independentReleaseCount
        parameterCount          = @($built.model.PSObject.Properties).Count
        lowConfidenceCount      = $lowCount
    })
}

$coveredIds = @($mapped | ForEach-Object { [string]$_.definitionId })
$uncovered  = @($entries | Where-Object { $coveredIds -notcontains [string]$_.id } |
                ForEach-Object { [pscustomobject]@{ scope = $_.scope; key = $_.key; definitionId = $_.id } })

$wrote = $false
if (-not $NoWrite -and $mapped.Count -gt 0) {
    Set-Content -LiteralPath $CatalogPath -Value ($catalog | ConvertTo-Json -Depth 30) -Encoding utf8NoBOM
    $wrote = $true
}

return [pscustomobject]@{
    catalogPath = $CatalogPath
    mapped      = $mapped.ToArray()
    unmapped    = $unmapped.ToArray()
    uncovered   = $uncovered
    wrote       = $wrote
}
