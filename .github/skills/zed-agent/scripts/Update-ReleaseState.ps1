function Update-ReleaseState {
    param(
        [Parameter(Mandatory)][string]$ReleaseId,
        [Parameter(Mandatory)][ValidateSet('read','write','update-step','set-directive')][string]$Action,
        [int]$StepNumber,
        [string]$StepStatus,
        [string]$DirectiveJson,
        [string]$AuditEntry
    )
    $baseDir = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId"
    $stateFile = Join-Path $baseDir "state.json"
    $auditFile = Join-Path $baseDir "audit.jsonl"
    $stateLock = Join-Path $baseDir "state.json.lock"

    . (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

    if ($Action -eq 'read') {
        if (-not (Test-Path $stateFile)) { throw "State file not found: $stateFile" }
        return Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    Invoke-WithStateLock -LockFile $stateLock -Action {
        # For write operations, create backup first
        if (Test-Path $stateFile) { Copy-Item $stateFile "$stateFile.bak" -Force }

        if ($Action -eq 'write') {
            $DirectiveJson | Set-Content $stateFile -Encoding UTF8 -NoNewline
        }
        elseif ($Action -eq 'update-step') {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $step = $state.steps | Where-Object { $_.number -eq $StepNumber }
            if (-not $step) { throw "Step $StepNumber not found" }
            $step.status = $StepStatus
            $now = (Get-Date).ToUniversalTime().ToString('o')
            if ($StepStatus -eq 'in-progress') { $step.startedAt = $now }
            if ($StepStatus -in @('completed','failed','skipped')) { $step.completedAt = $now }
            $state.lastUpdated = $now
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
        }
        elseif ($Action -eq 'set-directive') {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.watcherDirective = $DirectiveJson | ConvertFrom-Json
            $state.lastUpdated = (Get-Date).ToUniversalTime().ToString('o')
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
        }
    }

    # Append audit entry if provided
    if ($AuditEntry) {
        $AuditEntry | Add-Content $auditFile -Encoding UTF8
    }
    return @{ success = $true; path = $stateFile }
}
