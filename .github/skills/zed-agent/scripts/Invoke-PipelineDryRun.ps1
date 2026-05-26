<#
.SYNOPSIS
    Queues a real ADO pipeline run with the templateParameters from
    pipeline-catalog.json and cancels it within $CancelAfterSeconds. Used by
    setup-service Group 11 (Phase 11.2 / 11.3) to validate that the parameters
    learned during discovery are accepted by ADO without consuming a real
    deployment.

.DESCRIPTION
    Mirrors the queue+cancel pattern Step 15 test-mode already uses in
    production (see ZedAgent.agent.md Step 15) — POST a run, sleep, PATCH
    status=cancelling. Default 5 seconds is well below the typical ADO agent
    pickup time, so no actual deployment happens.

    Auth: az login (Entra). Token acquired with the ADO resource GUID.

    Reserved tokens in templateParameters are substituted with stub values
    BEFORE the POST so ADO sees concrete strings. The substitution table is
    inlined below so it can be audited and tweaked centrally.

.PARAMETER PipelineKey
    Either 'officialBuild', or a key from canary.<key> / production.<key>.
    Use 'canary:<key>' or 'production:<key>' for unambiguous selection.

.PARAMETER CatalogPath
    Path to pipeline-catalog.json.

.PARAMETER CancelAfterSeconds
    Seconds to wait between queue and cancel. Default 5.

.PARAMETER DryRunBranch
    Branch the run targets. Accepts either short ('develop') or full ref
    ('refs/heads/develop'). Default: 'develop'.

    The branch MUST exist in the target repo — ADO validates the ref
    synchronously at queue time (NOT at agent-pickup, contrary to the earlier
    docstring). The script derives:
      - branchRef   = 'refs/heads/<short>'  used ONLY for resources.repositories.self.refName
      - branchShort = '<short>'             used for {{currentBranch}} substitution in templateParameters

    templateParameters whose names contain 'Branch' / 'BranchName' are
    consumed by YAML as plain SHORT strings, not git refs.

.OUTPUTS
    PSCustomObject:
      pipelineKey, pipelineId, runId, runUrl, queuedAt, cancelledAt,
      finalState, queuedParameters, droppedParams, error (when something failed)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$PipelineKey,
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [int]$CancelAfterSeconds = 5,
    [string]$DryRunBranch = 'develop'
)

$ErrorActionPreference = 'Stop'

# ── Normalize branch: accept short or full ref, derive both forms ──
$branchShort = if ($DryRunBranch -match '^refs/heads/(.+)$') { $Matches[1] } else { $DryRunBranch }
$branchRef   = "refs/heads/$branchShort"

# ── Reserved-token stub values used ONLY during dry-runs ──
# These are intentionally inert: validateOnly=true means EV2 would no-op even
# if cancellation failed; currentBranch is the SHORT branch name (templateParameters
# expect short, not refs/heads/X); stamp / region lists are empty so even if the
# run ever picked up nothing would deploy.
$stubs = @{
    '{{currentBranch}}'  = $branchShort
    '{{excludeStamps}}'  = ''
    '{{pubRegions}}'     = ''
    '{{ffStamps}}'       = ''
    '{{ffRegions}}'      = ''
    '{{sdpType}}'        = 'Test'
    '{{validateOnly}}'   = 'true'
}

# ── Load catalog & resolve entry ──
if (-not (Test-Path $CatalogPath)) { throw "pipeline-catalog.json not found at $CatalogPath" }
$catalog = Get-Content $CatalogPath -Raw | ConvertFrom-Json

$entry = $null
$resolvedKey = $PipelineKey
if ($PipelineKey -eq 'officialBuild') {
    $entry = $catalog.officialBuild
} elseif ($PipelineKey -match '^(canary|production):(.+)$') {
    $section = $Matches[1]
    $key     = $Matches[2]
    if ($catalog.$section -and $catalog.$section.PSObject.Properties[$key]) {
        $entry = $catalog.$section.$key
        $resolvedKey = "$section.$key"
    }
} else {
    foreach ($section in @('canary','production')) {
        if ($catalog.$section -and $catalog.$section.PSObject.Properties[$PipelineKey]) {
            $entry = $catalog.$section.$PipelineKey
            $resolvedKey = "$section.$PipelineKey"
            break
        }
    }
}
if (-not $entry) { throw "Pipeline key '$PipelineKey' not found in $CatalogPath." }

# ── Substitute reserved tokens + drop params undeclared by YAML ──
# Token substitution is delegated to Resolve-TemplateParams.ps1 — it knows the
# token table, reads inventory + routing, filters stamps by clusterType when
# routing mode is "cluster-type", and throws CLUSTER_TYPE_CONTAMINATION if a
# stamp would land in a pipeline whose clusterType does not match. Keeping
# substitution out of this script means the dry-run and Step 15 (real release)
# can never diverge on token semantics.
#
# YAML-undeclared param drop stays here: ADO rejects the entire queue request
# on ANY templateParameter the YAML does not declare on the target branch.
# Surface dropped names so the caller can persist them to
# catalog.<group>.<key>._learnedFrom.dryRun.droppedParams[].
$declared = $null
if ($entry.yamlIntrospection -and $entry.yamlIntrospection.parameters) {
    $declared = @($entry.yamlIntrospection.parameters | ForEach-Object { $_.name })
}

$resolverScope = $null
$resolverKey   = $null
if ($resolvedKey -match '^(canary|production)\.(.+)$') {
    $resolverScope = $Matches[1]
    $resolverKey   = $Matches[2]
}

$substituted    = @{}
$droppedParams  = @()
$resolverDiag   = $null

if ($resolverScope) {
    # canary / production pipeline — delegate substitution to the resolver.
    $resolveScript = Join-Path $PSScriptRoot 'Resolve-TemplateParams.ps1'
    if (-not (Test-Path $resolveScript)) { throw "Resolve-TemplateParams.ps1 sibling script missing at $resolveScript." }
    $r = & $resolveScript -PipelineKey $resolverKey -Scope $resolverScope -CurrentBranch $branchShort -PipelineCatalogPath $CatalogPath
    $resolverDiag = $r
    foreach ($k in $r.templateParameters.Keys) {
        if ($declared -and ($declared -notcontains $k)) {
            $droppedParams += $k
            continue
        }
        $substituted[$k] = $r.templateParameters[$k]
    }
} else {
    # officialBuild — no clusterType, no inventory tokens. Apply legacy stubs
    # inline for currentBranch / validateOnly / sdpType.
    foreach ($p in $entry.templateParameters.PSObject.Properties) {
        if ($declared -and ($declared -notcontains $p.Name)) {
            $droppedParams += $p.Name
            continue
        }
        $v = $p.Value
        if ($v -is [string] -and $stubs.ContainsKey($v)) { $v = $stubs[$v] }
        $substituted[$p.Name] = $v
    }
}

# ── Token ──
$adoToken = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query accessToken -o tsv 2>$null
if (-not $adoToken) { throw "Failed to acquire ADO API token. Run 'az login --tenant microsoft.com'." }
$headers = @{ Authorization = "Bearer $adoToken"; 'Content-Type' = 'application/json' }
$orgBase = "https://dev.azure.com/$Organization/$Project/_apis"

# ── Queue the run ──
$queueUri = "$orgBase/pipelines/$($entry.id)/runs?api-version=7.1-preview.1"
$body = @{
    resources = @{
        repositories = @{
            self = @{ refName = $branchRef }
        }
    }
    templateParameters = $substituted
} | ConvertTo-Json -Depth 16

$queuedAt = (Get-Date).ToUniversalTime().ToString('o')
$runId = $null
$runUrl = $null
$queueError = $null
try {
    $resp = Invoke-RestMethod -Uri $queueUri -Method POST -Headers $headers -Body $body -ErrorAction Stop
    $runId  = $resp.id
    $runUrl = "https://dev.azure.com/$Organization/$Project/_build/results?buildId=$runId"
} catch {
    $queueError = "$($_.Exception.Message)"
    return [PSCustomObject]@{
        pipelineKey      = $resolvedKey
        pipelineId       = $entry.id
        runId            = $null
        runUrl           = $null
        queuedAt         = $queuedAt
        cancelledAt      = $null
        finalState       = 'queue-failed'
        queuedParameters = $substituted
        droppedParams    = $droppedParams
        error            = $queueError
    }
}

# ── Sleep + cancel ──
Start-Sleep -Seconds $CancelAfterSeconds

$cancelUri = "$orgBase/build/builds/${runId}?api-version=7.0"
$cancelBody = @{ status = 'cancelling' } | ConvertTo-Json
$cancelledAt = $null
$cancelError = $null
$attempts = 0
$maxAttempts = 3
while ($attempts -lt $maxAttempts) {
    $attempts++
    try {
        Invoke-RestMethod -Uri $cancelUri -Method PATCH -Headers $headers -Body $cancelBody -ErrorAction Stop | Out-Null
        $cancelledAt = (Get-Date).ToUniversalTime().ToString('o')
        break
    } catch {
        $cancelError = "$($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}

# ── Poll once for final state ──
$finalState = 'unknown'
try {
    $detail = Invoke-RestMethod -Uri "$orgBase/build/builds/${runId}?api-version=7.0" -Headers $headers -ErrorAction Stop
    $finalState = if ($detail.status -eq 'completed') { $detail.result } else { $detail.status }
} catch { }

return [PSCustomObject]@{
    pipelineKey      = $resolvedKey
    pipelineId       = $entry.id
    runId            = $runId
    runUrl           = $runUrl
    queuedAt         = $queuedAt
    cancelledAt      = $cancelledAt
    finalState       = $finalState
    queuedParameters = $substituted
    droppedParams    = $droppedParams
    error            = $cancelError
}
