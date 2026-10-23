<#
.SYNOPSIS
    Layer 3 drift-halt handler. Single entry point invoked by ZedAgent
    Steps 5, 7, 10, and 15 whenever Resolve-PipelinesByClusterType.ps1
    throws with prefix "DRIFT_HALT:".

.DESCRIPTION
    Performs the full drift-halt protocol in one atomic call:
      1. Parses the drift list (either supplied via -DriftRows or
         extracted from -ResolverError).
      2. Flips the step to status "failed-drift" and attaches a
         driftPayload via Update-ReleaseState (single state lock).
      3. Writes a canonical audit row to audit.jsonl
         (event = "drift-halt").
      4. Resolves Teams recipients via Resolve-NotificationRecipients
         using EventKey "step-<N>-failed".
      5. Renders templates/drift-halt-message.html and posts to every
         resolved Teams conversation via Send-TeamsMessage.

    Out of scope (caller / agent narrative responsibility):
      - Owner-only email per Behavior Rule 11 (use SendEmailWithAttachments).
      - Watching the Teams thread for owner reply ("mitigated" / "approve drift").
        Release-Watcher recognises "failed-drift" status and re-sends a
        reminder if the step sits in that state >24h, but the actual
        re-queue is initiated by the agent when the owner replies.

    Returns a PSCustomObject summarising what was done so the caller
    can log it or surface it to the user.

.PARAMETER ReleaseId
    Release id (e.g. "2026-05") matching .zed-agent/releases/<id>.

.PARAMETER StepNumber
    Pipeline step number (5, 7, 10, or 15).

.PARAMETER StepName
    Short display name (e.g. "Canary Deployment") used in the Teams
    message subject line.

.PARAMETER Scope
    "canary" or "production" — matches the resolver -Scope value.

.PARAMETER DriftRows
    Array of PSCustomObject / hashtable with fields { stampName, reason, source }.
    Either this OR -ResolverError must be supplied.

.PARAMETER ResolverError
    Raw exception message from the resolver (the "DRIFT_HALT: ..." string).
    Used to parse drift rows when -DriftRows is not supplied directly.

.PARAMETER ServiceConfigPath
    Optional. Defaults to repo-root .github/skills/zed-agent/service-config.json.

.PARAMETER SkipTeams
    Test-mode switch. Skips Send-TeamsMessage but still updates state and
    audit. Used by Pester.

.PARAMETER SkipStateUpdate
    Test-mode switch. Skips Update-ReleaseState (Pester uses this when no
    release dir exists).

.OUTPUTS
    PSCustomObject {
      releaseId, step, scope, driftCount, driftRows[],
      auditWritten (bool), stateUpdated (bool),
      teamsPosted = @(@{ conversationId; ok; error })
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][int]$StepNumber,
    [Parameter(Mandatory)][string]$StepName,
    [Parameter(Mandatory)][ValidateSet('canary','production')][string]$Scope,
    [object[]]$DriftRows,
    [string]$ResolverError,
    [string]$ServiceConfigPath,
    [string]$Branch,
    [string]$ReleaseOwner,
    [string]$TemplatePath,
    [switch]$SkipTeams,
    [switch]$SkipStateUpdate
)

$ErrorActionPreference = 'Stop'

# ── Locate templates / scripts ────────────────────────────────────────
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\')).Path
$skillDir = Join-Path $repoRoot '.github\skills\zed-agent'
if (-not $TemplatePath)       { $TemplatePath       = Join-Path $skillDir 'templates\drift-halt-message.html' }
if (-not $ServiceConfigPath)  { $ServiceConfigPath  = Join-Path $skillDir 'service-config.json' }

# ── Normalise drift rows ──────────────────────────────────────────────
if (-not $DriftRows -or @($DriftRows).Count -eq 0) {
    if (-not $ResolverError) {
        throw "Invoke-DriftHalt requires either -DriftRows or -ResolverError."
    }
    # Resolver throws: "DRIFT_HALT: <scope> inventory has N drift row(s)...:`n - <stampName>: <reason>`n - ..."
    $DriftRows = @()
    foreach ($line in ($ResolverError -split "`n")) {
        $m = [regex]::Match($line.TrimEnd(), '^\s*-\s*(?<name>[^:]+):\s*(?<reason>.+)$')
        if ($m.Success) {
            $DriftRows += [PSCustomObject]@{
                stampName = $m.Groups['name'].Value.Trim()
                reason    = $m.Groups['reason'].Value.Trim()
                source    = 'resolver'
            }
        }
    }
}
$DriftRows = @($DriftRows)
if ($DriftRows.Count -eq 0) {
    throw "Invoke-DriftHalt could not derive any drift rows from inputs. Refusing to halt silently."
}

$nowIso = (Get-Date).ToUniversalTime().ToString('o')
$result = [PSCustomObject]@{
    releaseId    = $ReleaseId
    step         = $StepNumber
    scope        = $Scope
    driftCount   = $DriftRows.Count
    driftRows    = $DriftRows
    haltedAt     = $nowIso
    auditWritten = $false
    stateUpdated = $false
    teamsPosted  = @()
}

# ── State + audit (single lock via Update-ReleaseState) ───────────────
if (-not $SkipStateUpdate) {
    $updateScript = Join-Path $PSScriptRoot 'Update-ReleaseState.ps1'
    . $updateScript
    $auditEntry = @{
        ts    = $nowIso
        event = 'drift-halt'
        step  = $StepNumber
        scope = $Scope
        drift = @($DriftRows | ForEach-Object {
            @{ stampName = "$($_.stampName)"; reason = "$($_.reason)"; source = "$($_.source)" }
        })
    } | ConvertTo-Json -Compress -Depth 6
    $payload = @{
        driftPayload = @{
            haltedAt = $nowIso
            scope    = $Scope
            count    = $DriftRows.Count
            rows     = @($DriftRows | ForEach-Object {
                @{ stampName = "$($_.stampName)"; reason = "$($_.reason)"; source = "$($_.source)" }
            })
        }
    }
    Update-ReleaseState -ReleaseId $ReleaseId -Action update-step -StepNumber $StepNumber `
        -StepStatus 'failed-drift' -AuditEntry $auditEntry -StepPayload $payload | Out-Null
    $result.stateUpdated = $true
    $result.auditWritten = $true
}

# ── Teams posting ─────────────────────────────────────────────────────
if (-not $SkipTeams) {
    # Build the {{driftRows}} HTML table body.
    $rowsHtml = ($DriftRows | ForEach-Object {
        $name   = [System.Web.HttpUtility]::HtmlEncode("$($_.stampName)")
        $reason = [System.Web.HttpUtility]::HtmlEncode("$($_.reason)")
        $src    = [System.Web.HttpUtility]::HtmlEncode("$($_.source)")
        "<tr><td style=`"padding:6px 12px;`"><code>$name</code></td><td style=`"padding:6px 12px;`">$reason</td><td style=`"padding:6px 12px;`">$src</td></tr>"
    }) -join "`n"

    $vars = @{
        scope         = $Scope
        stepNumber    = "$StepNumber"
        stepName      = $StepName
        releaseId     = $ReleaseId
        branch        = if ($Branch)        { $Branch }        else { '(unknown)' }
        releaseOwner  = if ($ReleaseOwner)  { $ReleaseOwner }  else { '(unknown)' }
        haltedAt      = $nowIso
        driftCount    = "$($DriftRows.Count)"
        driftRows     = $rowsHtml
    }

    # Resolve Teams conversations. Best-effort — if any of these dependencies
    # is missing in a degraded environment, we still want the state/audit
    # write above to succeed, so wrap in try/catch and report per-channel.
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $loadCfg = Join-Path $PSScriptRoot 'Load-ServiceConfig.ps1'
        $cfg     = & $loadCfg -ServiceConfigPath $ServiceConfigPath
        $stateFile = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId/state.json"
        $release = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ id = $ReleaseId } }
        $secretsFile = Join-Path (Get-Location) '.zed-agent/secrets.json'
        $secrets = if (Test-Path $secretsFile) { Get-Content $secretsFile -Raw | ConvertFrom-Json } else { $null }
        $resolveScript = Join-Path $PSScriptRoot 'Resolve-NotificationRecipients.ps1'
        . $resolveScript
        $recipients = Resolve-NotificationRecipients -EventKey "step-$StepNumber-failed" -Config $cfg -Release $release -Secrets $secrets
        $sendScript = Join-Path $PSScriptRoot 'Send-TeamsMessage.ps1'
        . $sendScript

        $posted = @()
        foreach ($conv in @($recipients.TeamsConversationIds)) {
            if (-not $conv) { continue }
            try {
                Send-TeamsMessage -ConversationId $conv -TemplatePath $TemplatePath -Variables $vars -Subject "🛑 Drift halt — $Scope — Step $StepNumber" | Out-Null
                $posted += @{ conversationId = $conv; ok = $true; error = $null }
            } catch {
                $posted += @{ conversationId = $conv; ok = $false; error = $_.Exception.Message }
            }
        }
        $result.teamsPosted = $posted
    } catch {
        Write-Warning "Invoke-DriftHalt: Teams notification failed: $($_.Exception.Message). State + audit were still written."
        $result.teamsPosted = @(@{ conversationId = $null; ok = $false; error = $_.Exception.Message })
    }
}

return $result
