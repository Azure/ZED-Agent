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
        $StepPayload,
        # Optional: extra top-level properties to merge into state.json on write.
        # Used for atomicity fixes (e.g., pipelineTriggerTimestamps, triggeredPipelines).
        # Accepts hashtable or PSCustomObject.
        $StateProperties
    )
    # Resolve paths: supports both .zed-release/ (durable/cloud) and .zed-agent/ (local)
    $resolveScript = Join-Path $PSScriptRoot 'Resolve-StatePaths.ps1'
    if (Test-Path $resolveScript) {
        $paths = & $resolveScript -ReleaseId $ReleaseId
        $baseDir   = Split-Path $paths.StateFile -Parent
        $stateFile = $paths.StateFile
        $auditFile = $paths.AuditFile
        # Lock always lives in scratch (never committed)
        $stateLock = $paths.LockFile
    } else {
        # Fallback for backward compatibility
        $baseDir = Join-Path (Get-Location) ".zed-agent/releases/$ReleaseId"
        $stateFile = Join-Path $baseDir "state.json"
        $auditFile = Join-Path $baseDir "audit.jsonl"
        $stateLock = Join-Path $baseDir "state.json.lock"
    }

    . (Join-Path $PSScriptRoot 'Invoke-WithStateLock.ps1')

    if ($Action -eq 'read') {
        if (-not (Test-Path $stateFile)) { throw "State file not found: $stateFile" }
        return Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    Invoke-WithStateLock -LockFile $stateLock -Action ({
        # For write operations, create backup first — but never overwrite a good backup
        # with an empty/corrupt state file (that is how the only recovery copy was lost).
        if (Test-Path $stateFile) {
            if ((Get-Item $stateFile).Length -gt 0) { Copy-Item $stateFile "$stateFile.bak" -Force }
        }

        if ($Action -eq 'write') {
            # Guard: a bare -Action write with no DirectiveJson used to truncate state.json to
            # 0 bytes. The spec (Steps 5/10 atomicity) calls Update-ReleaseState with
            # -StateProperties only, so support that here as a merge instead of a clobber.
            if ([string]::IsNullOrWhiteSpace($DirectiveJson)) {
                if ($null -eq $StateProperties) {
                    throw "Update-ReleaseState -Action write requires either -DirectiveJson (full state document) or -StateProperties (merge). Refusing to truncate $stateFile."
                }
                if (-not (Test-Path $stateFile)) { throw "State file not found: $stateFile" }
                $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $stateProps = if ($StateProperties -is [hashtable]) { $StateProperties.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } }
                              else { $StateProperties.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } } }
                foreach ($sp in $stateProps) {
                    if ($state.PSObject.Properties[$sp.Name]) { $state.($sp.Name) = $sp.Value }
                    else { Add-Member -InputObject $state -MemberType NoteProperty -Name $sp.Name -Value $sp.Value -Force }
                }
                $state.lastUpdated = (Get-Date).ToUniversalTime().ToString('o')
                $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8 -NoNewline
            }
            else {
                $DirectiveJson | Set-Content $stateFile -Encoding UTF8 -NoNewline
            }
        }
        elseif ($Action -eq 'update-step') {
            $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $step = $state.steps | Where-Object { $_.number -eq $StepNumber }
            if (-not $step) { throw "Step $StepNumber not found" }
            $step.status = $StepStatus
            $now = (Get-Date).ToUniversalTime().ToString('o')
            # Step skeletons may omit startedAt/completedAt (e.g. {number,name,status}); add them on demand.
            if ($StepStatus -eq 'in-progress') { Add-Member -InputObject $step -MemberType NoteProperty -Name startedAt -Value $now -Force }
            if ($StepStatus -in @('completed','failed','skipped') -or $StepStatus -like 'failed-*') { Add-Member -InputObject $step -MemberType NoteProperty -Name completedAt -Value $now -Force }
            if ($null -ne $StepPayload) {
                $payloadProps = if ($StepPayload -is [hashtable]) { $StepPayload.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } }
                                else { $StepPayload.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } } }
                foreach ($p in $payloadProps) {
                    if ($step.PSObject.Properties[$p.Name]) { $step.($p.Name) = $p.Value }
                    else { Add-Member -InputObject $step -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force }
                }
            }
            # Merge top-level StateProperties (atomicity: pipelineTriggerTimestamps, triggeredPipelines, etc.)
            if ($null -ne $StateProperties) {
                $stateProps = if ($StateProperties -is [hashtable]) { $StateProperties.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } } }
                              else { $StateProperties.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } } }
                foreach ($sp in $stateProps) {
                    if ($state.PSObject.Properties[$sp.Name]) { $state.($sp.Name) = $sp.Value }
                    else { Add-Member -InputObject $state -MemberType NoteProperty -Name $sp.Name -Value $sp.Value -Force }
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
        # Also render a human-readable line to audit.md
        $auditMdFile = [System.IO.Path]::ChangeExtension($auditFile, '.md')
        try {
            $parsed = $AuditEntry | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed) {
                $ts = if ($parsed.ts) { $parsed.ts } elseif ($parsed.timestamp) { $parsed.timestamp } else { (Get-Date -Format 'o') }
                $ev = if ($parsed.event) { $parsed.event } elseif ($parsed.action) { $parsed.action } else { 'unknown' }
                $extra = ($parsed.PSObject.Properties | Where-Object { $_.Name -notin @('ts','timestamp','event','action') } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
                $mdLine = "| $ts | $ev | $extra |"
                if (-not (Test-Path $auditMdFile)) {
                    "# Audit Log`n`n| Timestamp | Event | Details |`n|-----------|-------|---------|" | Set-Content $auditMdFile -Encoding UTF8
                }
                $mdLine | Add-Content $auditMdFile -Encoding UTF8
            }
        } catch { <# audit.md rendering is best-effort #> }
    }
    return @{ success = $true; path = $stateFile }
}
