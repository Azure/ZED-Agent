# Invoke-WithStateLock.ps1
# Acquires an exclusive cross-process file lock on $LockFile, runs $Action, then releases the lock.
# Used to serialize read-modify-write on state.json between the interactive agent and Release-Watcher.
function Invoke-WithStateLock {
    param(
        [Parameter(Mandatory)][string]$LockFile,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stream = $null
    $lockDir = Split-Path -Parent $LockFile
    if ($lockDir -and -not (Test-Path $lockDir)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
    while (-not $stream) {
        try {
            $stream = [System.IO.File]::Open(
                $LockFile,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            if ((Get-Date) -gt $deadline) { throw "Timed out acquiring state lock: $LockFile" }
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        & $Action
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}
