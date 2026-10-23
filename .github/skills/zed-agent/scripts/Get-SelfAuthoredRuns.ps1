<#
.SYNOPSIS
    Returns the ledger of pipeline runs that ZED itself authored, so that no
    learning path can ever mistake ZED's own output for a human reference run.

.DESCRIPTION
    ZED learns the "right" templateParameters by reading prior runs of a
    pipeline. If ZED's own trigger-and-cancel runs are in that history, ZED
    learns its own mistakes and they become permanent.

    Filtering by identity does not work: ZED runs under the release owner's
    delegated token, so `requestedFor` and `reason` are identical for a run a
    human queued from the ADO UI and a run ZED queued via the REST API. The
    only reliable discriminator is a ledger of run ids ZED recorded at the
    moment it triggered them.

    Sources merged (union, most-recent-wins on metadata):
      1. The durable ledger file, if it already exists.
      2. Every `.zed-agent/releases/<id>/test-run-capture.json` in the repo —
         ZED writes one record per trigger, each carrying its own runId.
      3. Any ids passed with -AddRunId (for runs recorded out of band).

    Pure read unless -Persist is supplied.

.PARAMETER RepoRoot
    Root of the deployment repo (the one containing `.zed-agent/`).
    Defaults to the current directory.

.PARAMETER LedgerPath
    Override the ledger location. Defaults to
    <RepoRoot>/.zed-agent/self-authored-runs.json

.PARAMETER AddRunId
    Additional run ids to fold into the ledger.

.PARAMETER Persist
    Write the merged ledger back to disk.

.PARAMETER IdsOnly
    Emit just the sorted int[] of run ids instead of the full object.

.OUTPUTS
    PSCustomObject { ledgerPath, runIds (int[]), records (array), sources }
    or int[] when -IdsOnly.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$LedgerPath,
    [int[]]$AddRunId = @(),
    [switch]$Persist,
    [switch]$IdsOnly
)

$ErrorActionPreference = 'Stop'

if (-not $LedgerPath) {
    $LedgerPath = Join-Path $RepoRoot '.zed-agent\self-authored-runs.json'
}

$byId    = [ordered]@{}
$sources = New-Object System.Collections.Generic.List[string]

function Add-Record {
    param([object]$Record)
    if (-not $Record) { return }
    $id = 0
    if (-not [int]::TryParse([string]$Record.runId, [ref]$id) -or $id -le 0) { return }
    $key = [string]$id
    if ($byId.Contains($key)) {
        # Keep the richest record we have seen.
        $existing = $byId[$key]
        foreach ($prop in $Record.PSObject.Properties) {
            if ($null -ne $prop.Value -and $null -eq $existing.$($prop.Name)) {
                $existing | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            }
        }
        return
    }
    $byId[$key] = [pscustomobject]@{
        runId      = $id
        pipelineId = $Record.pipelineId
        releaseId  = $Record.releaseId
        step       = $Record.step
        at         = $Record.at
    }
}

# ── 1. Existing ledger ──
if (Test-Path -LiteralPath $LedgerPath) {
    try {
        $existing = Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json
        foreach ($r in @($existing.runs)) { Add-Record -Record $r }
        $sources.Add("ledger:$LedgerPath") | Out-Null
    } catch {
        Write-Warning "Self-authored ledger at $LedgerPath is unreadable — rebuilding from captures. $($_.Exception.Message)"
    }
}

# ── 2. Trigger captures written by ZED at trigger time ──
$releasesDir = Join-Path $RepoRoot '.zed-agent\releases'
if (Test-Path -LiteralPath $releasesDir) {
    $captures = @(Get-ChildItem -LiteralPath $releasesDir -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'test-run-capture.json' } |
                  Where-Object { Test-Path -LiteralPath $_ })
    foreach ($cap in $captures) {
        $releaseId = Split-Path (Split-Path $cap -Parent) -Leaf
        try { $json = Get-Content -LiteralPath $cap -Raw | ConvertFrom-Json }
        catch { Write-Warning "Unreadable capture ${cap}: $($_.Exception.Message)"; continue }
        foreach ($rec in @($json)) {
            if (-not $rec.runId) { continue }
            Add-Record -Record ([pscustomobject]@{
                runId      = $rec.runId
                pipelineId = $rec.pipelineId
                releaseId  = $releaseId
                step       = $rec.step
                at         = $rec.ts
            })
        }
        $sources.Add("capture:$releaseId") | Out-Null
    }
}

# ── 3. Explicit additions ──
foreach ($id in @($AddRunId)) {
    Add-Record -Record ([pscustomobject]@{
        runId = $id; pipelineId = $null; releaseId = $null; step = $null
        at = (Get-Date).ToUniversalTime().ToString('o')
    })
}

$records = @($byId.Values | Sort-Object -Property runId)
$ids     = @($records | ForEach-Object { [int]$_.runId })

if ($Persist) {
    $dir = Split-Path $LedgerPath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload = [ordered]@{
        description = 'Pipeline runs authored by ZED itself. Excluded from every parameter-learning path so ZED never learns from its own output.'
        updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
        runs        = $records
    }
    Set-Content -LiteralPath $LedgerPath -Value ($payload | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
}

if ($IdsOnly) { return $ids }

return [pscustomobject]@{
    ledgerPath = $LedgerPath
    runIds     = $ids
    records    = $records
    sources    = @($sources.ToArray())
}
