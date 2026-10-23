<#
.SYNOPSIS
    Read/initialise/update the ZedForge loop state (forge-state.json).

.DESCRIPTION
    forge-state.json is the runtime tracker for the self-improvement loop:
    status, target repo, current iteration, and a per-iteration history
    (applied learnings, validation release id, verifier verdict, harvested
    learnings). It is local/runtime — gitignored.

.PARAMETER Action
    read            -> return the state object (or an empty skeleton if absent).
    init            -> create a fresh state (overwrites) with -TargetRepo.
    update          -> merge -Fields into the top-level object.
    append-iteration-> append -Iteration to iterations[] and bump currentIteration.

.PARAMETER StatePath
    Override path. Default: <skill>/state/forge-state.json.

.PARAMETER TargetRepo
    Target deployment repo (used by init).

.PARAMETER Fields
    Hashtable of top-level fields to merge (update).

.PARAMETER Iteration
    Hashtable iteration record to append (append-iteration).
#>
[CmdletBinding()]
param(
    [ValidateSet('read', 'init', 'update', 'append-iteration')][string]$Action = 'read',
    [string]$StatePath,
    [string]$TargetRepo,
    [hashtable]$Fields,
    [hashtable]$Iteration
)

$ErrorActionPreference = 'Stop'

if (-not $StatePath) {
    $StatePath = Join-Path $PSScriptRoot '..\state\forge-state.json'
}
$stateDir = Split-Path $StatePath -Parent
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

function Read-State {
    if (-not (Test-Path $StatePath)) {
        return [pscustomobject]@{
            status           = 'idle'
            targetRepo       = $null
            startedAt        = $null
            lastUpdated      = $null
            currentIteration = 0
            iterations       = @()
        }
    }
    return Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-State($obj) {
    $obj.lastUpdated = (Get-Date).ToUniversalTime().ToString('o')
    ($obj | ConvertTo-Json -Depth 20) | Set-Content $StatePath -Encoding UTF8
}

switch ($Action) {
    'read' { return Read-State }

    'init' {
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $obj = [pscustomobject]@{
            status               = 'running'
            targetRepo           = $TargetRepo
            startedAt            = $now
            lastUpdated          = $now
            currentIteration     = 0
            iterations           = @()
            implementedLearnings = @()
        }
        Write-State $obj
        return $obj
    }

    'update' {
        $obj = Read-State
        if ($Fields) {
            foreach ($k in $Fields.Keys) {
                if ($obj.PSObject.Properties[$k]) { $obj.$k = $Fields[$k] }
                else { Add-Member -InputObject $obj -MemberType NoteProperty -Name $k -Value $Fields[$k] -Force }
            }
        }
        Write-State $obj
        return $obj
    }

    'append-iteration' {
        if (-not $Iteration) { throw "append-iteration requires -Iteration." }
        $obj = Read-State
        $list = @($obj.iterations) + [pscustomobject]$Iteration
        $obj.iterations = $list
        $obj.currentIteration = $list.Count
        Write-State $obj
        return $obj
    }
}
