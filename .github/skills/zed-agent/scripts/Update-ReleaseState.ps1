function Update-ReleaseState {
    param(
        [Parameter(Mandatory)][string]$ReleaseId,
        [Parameter(Mandatory)][ValidateSet('read','write','update-step','set-directive')][string]$Action,
        [int]$StepNumber,
        [string]$StepStatus,
        [string]$DirectiveJson,
        [string]$AuditEntry,
        # Optional per-step extra fields merged into steps[$n] on update-step.
        # Used by Layer 3 drift-halt to attach 'driftPayload' alongside the
        # status flip (single lock, single write). Accepts hashtable or
        # PSCustomObject; existing keys on the step are overwritten.
        $StepPayload
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

    Invoke-WithStateLock -LockFile $stateLock -Action ({
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
            if ($StepStatus -in @('completed','failed','skipped') -or $StepStatus -like 'failed-*') { $step.completedAt = $now }
            if ($null -ne $StepPayload) {
                $payloadProps = if ($StepPayload -is [hashtable]) { $StepPayload.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } }
                                else { $StepPayload.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } } }
                foreach ($p in $payloadProps) {
                    if ($step.PSObject.Properties[$p.Name]) { $step.($p.Name) = $p.Value }
                    else { Add-Member -InputObject $step -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force }
                }
            }
            $state.lastUpdated = $now
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
        }
        elseif ($Action -eq 'set-directive') {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.watcherDirective = $DirectiveJson | ConvertFrom-Json
            $state.lastUpdated = (Get-Date).ToUniversalTime().ToString('o')
            $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
        }
    }.GetNewClosure())

    # Append audit entry if provided
    if ($AuditEntry) {
        $AuditEntry | Add-Content $auditFile -Encoding UTF8
    }
    return @{ success = $true; path = $stateFile }
}
