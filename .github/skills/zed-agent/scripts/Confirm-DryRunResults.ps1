<#
.SYNOPSIS
    Render a dry-run review block from Invoke-PipelineDryRun results and
    capture the release owner's verdict. Persisted to audit.jsonl and to
    readiness.json -> dryRun.reviewed.

.DESCRIPTION
    Called by setup-service Phases 4.11 (canary) and 4.12 (production) AFTER
    the fan-out of dry runs completes. The agent feeds the array of result
    objects (one per pipeline) and the scope. This script:

      1. Composes a markdown table the agent SHOULD echo to the user.
      2. Returns a $script-scoped object describing what the agent must
         ask next: { table, prompt, choices, scope }.
      3. After the agent collects an answer, the agent calls back with
         -Verdict and (optionally) -Discrepancy, and the script writes
         audit.jsonl + readiness.json.

    Two-call shape is used so the *prompt* is owned by the agent (which has
    the user-facing channel) while persistence stays in one file.

.PARAMETER Mode
    'render'  -> returns { table, prompt, choices, scope }. Agent must echo
                 the table and ask the prompt.
    'record'  -> writes verdict to audit.jsonl + readiness.json.

.PARAMETER Results
    Array of PSCustomObject from Invoke-PipelineDryRun.ps1.

.PARAMETER Scope
    'canary' | 'production'.

.PARAMETER Verdict
    Required when Mode='record'. One of 'ok' | 'discrepancy' | 'rerun'.

.PARAMETER Discrepancy
    Optional free-form string describing the issue when Verdict='discrepancy'.

.PARAMETER ReadinessPath
    Override default .zed-agent/readiness.json.

.OUTPUTS
    Mode='render':  PSCustomObject { table, prompt, choices, scope, validatedKeys }
    Mode='record':  PSCustomObject { verdict, validatedKeys, discrepancy, advancePhase }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('render','record')] [string] $Mode,
    [Parameter(Mandatory)] [array] $Results,
    [Parameter(Mandatory)] [ValidateSet('canary','production')] [string] $Scope,
    [ValidateSet('ok','discrepancy','rerun')] [string] $Verdict,
    [string] $Discrepancy,
    [string] $ReadinessPath
)

$ErrorActionPreference = 'Stop'

if (-not $ReadinessPath) {
    $baseDir = Join-Path (Get-Location) '.zed-agent'
    if (-not (Test-Path $baseDir)) { New-Item -ItemType Directory -Path $baseDir -Force | Out-Null }
    $ReadinessPath = Join-Path $baseDir 'readiness.json'
}
$auditPath = Join-Path (Split-Path $ReadinessPath -Parent) 'audit.jsonl'

# Pipelines that even reached ADO get treated as candidates for validation.
$validatedKeys = @($Results | Where-Object { $_.runId -and $_.finalState -ne 'queue-failed' } | ForEach-Object { $_.pipelineKey })

if ($Mode -eq 'render') {
    $rows = foreach ($r in $Results) {
        $drop = if ($r.PSObject.Properties['droppedStamps']) { @($r.droppedStamps).Count } else { 0 }
        $gaps = if ($r.PSObject.Properties['agentGaps'])     { @($r.agentGaps).Count }     else { 0 }
        "| $($r.pipelineKey) | $($r.runId) | $($r.finalState) | $drop | $gaps | $($r.runUrl) |"
    }
    $table = @(
        "| Pipeline | RunId | FinalState | DroppedStamps | AgentGaps | URL |",
        "|---|---|---|---|---|---|"
    ) + $rows -join "`n"

    $prompt  = "Phase 4.$(if($Scope -eq 'canary'){'11'}else{'12'}) — review the $Scope dry-run results above. Each run was queued + cancelled so no SDP actually fired. Confirm the template parameters that were posted match what you expect."
    $choices = @('All good — proceed', 'Report a discrepancy', 'Re-run dry-runs')

    [PSCustomObject]@{
        table          = $table
        prompt         = $prompt
        choices        = $choices
        scope          = $Scope
        validatedKeys  = $validatedKeys
    }
    return
}

# Mode = 'record'
if (-not $Verdict) { throw "Mode='record' requires -Verdict." }

$row = [ordered]@{
    ts            = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    event         = 'dry-run-review'
    scope         = $Scope
    verdict       = $Verdict
    validatedKeys = $validatedKeys
    discrepancy   = $Discrepancy
} | ConvertTo-Json -Compress -Depth 6
Add-Content -Path $auditPath -Value $row

# Only update dryRun.reviewed=true on 'ok'. discrepancy/rerun leaves the gate closed.
if ($Verdict -eq 'ok') {
    $current = @{}
    if (Test-Path $ReadinessPath) {
        try { $current = Get-Content $ReadinessPath -Raw | ConvertFrom-Json -AsHashtable } catch { $current = @{} }
    }
    if (-not $current['dryRun']) { $current['dryRun'] = @{} }
    $current['dryRun']['reviewed']   = $true
    $current['dryRun']['reviewedAt'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $current['dryRun']['reviewedScope'] = $Scope
    $current['dryRun']['validatedKeys'] = $validatedKeys
    $json = $current | ConvertTo-Json -Depth 20
    Set-Content -Path $ReadinessPath -Value $json -Encoding UTF8 -NoNewline
    Add-Content -Path $ReadinessPath -Value "`n"
}

$advance = switch ($Verdict) {
    'ok'          { $true }
    'discrepancy' { $false }
    'rerun'       { $false }
}

[PSCustomObject]@{
    verdict       = $Verdict
    validatedKeys = $validatedKeys
    discrepancy   = $Discrepancy
    advancePhase  = $advance
}
