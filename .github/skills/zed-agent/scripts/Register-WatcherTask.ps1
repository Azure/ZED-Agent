function Register-ReleaseWatcherTask {
    param([string]$TaskName,[string]$Execute,[string]$Argument,[string]$WorkingDir,[string]$User,[string]$Description)
    $a = New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDir
    $tLogon = New-ScheduledTaskTrigger -AtLogOn -User $User
    # Recurring trigger: restart watcher every 30 minutes to survive sleep/lock/crash
    $tRecurring = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
    # MultipleInstances=StopExisting: on each 30-min trigger, kill any zombie
    # watcher (e.g. a process frozen by DevBox hibernation) before starting a
    # fresh instance. Without this the default IgnoreNew causes Task Scheduler
    # to log 0x800710E0 and silently drop the respawn while the zombie holds
    # watcher.lock — exactly the symptom we hit during the 2026-05 release.
    # NOTE: the ScheduledTasks module's MultipleInstancesEnum lacks 'StopExisting'
    # on some Windows/PowerShell versions (only Parallel/Queue/IgnoreNew), where
    # `-MultipleInstances StopExisting` throws "Cannot convert value StopExisting
    # to MultipleInstancesEnum". Try StopExisting; fall back to IgnoreNew (zombie
    # watchers are then handled by Register-WatcherTask -Action cleanup + the
    # watcher's own PID-liveness check on watcher.lock).
    # WakeToRun: ask Windows to wake from S3/S4 sleep to fire the trigger.
    $settingsArgs = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable         = $true
        WakeToRun                  = $true
        RestartCount               = 3
        RestartInterval            = (New-TimeSpan -Minutes 1)
    }
    try {
        $settings = New-ScheduledTaskSettingsSet @settingsArgs -MultipleInstances StopExisting
    } catch {
        $settings = New-ScheduledTaskSettingsSet @settingsArgs -MultipleInstances IgnoreNew
    }
    Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger @($tLogon, $tRecurring) -Settings $settings -Description $Description -Force | Out-Null
}

function Register-WatcherTask {
    param(
        [Parameter(Mandatory)][ValidateSet('register','unregister','cleanup')][string]$Action,
        [string]$ReleaseId,
        [string]$WatcherScriptPath = (Join-Path (git rev-parse --show-toplevel) ".github\skills\zed-agent\scripts\Release-Watcher.ps1"),
        [string]$RepoRoot = (Get-Location).Path,
        [string]$ServiceConfigPath = (Join-Path $PSScriptRoot '..\service-config.json')
    )

    $ErrorActionPreference = 'Stop'

    if ($Action -in @('register','unregister') -and -not $ReleaseId) {
        throw "ReleaseId is required for '$Action' action"
    }

    # --- Load service config ---
    $cfg = & (Join-Path $PSScriptRoot 'Load-ServiceConfig.ps1') -ServiceConfigPath $ServiceConfigPath

    $taskName = "$($cfg.operational.watcherTaskPrefix)-$ReleaseId"

    if ($Action -eq 'register') {
        $argStr = "-NoProfile -File `"$WatcherScriptPath`" -ReleaseId `"$ReleaseId`""
        $schtaskArgs = @{
            TaskName    = $taskName
            Execute     = 'pwsh'
            Argument    = $argStr
            WorkingDir  = $RepoRoot
            User        = $env:USERNAME
            Description = "$($cfg.operational.watcherTaskPrefix) watcher for release $ReleaseId"
        }
        Register-ReleaseWatcherTask @schtaskArgs
        return @{ success = $true; taskName = $taskName; action = 'registered' }
    }

    if ($Action -eq 'unregister') {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        return @{ success = $true; taskName = $taskName; action = 'unregistered' }
    }

    if ($Action -eq 'cleanup') {
        # Remove ALL ZED watcher tasks (current + any orphaned/stale from prior runs).
        # Guard against null/empty prefix — an empty prefix would match all tasks on the machine.
        $prefix = "$($cfg.operational.watcherTaskPrefix)".Trim()
        $removed = @()
        $errors  = @()
        if ($prefix) {
            Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$prefix*" } | ForEach-Object {
                try {
                    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                    $removed += $_.TaskName
                } catch {
                    $errors += "unregister '$($_.TaskName)': $_"
                }
            }
        }
        # Kill any running watcher processes.
        # MUST exclude this process and its ancestors: the cleanup call itself runs
        # from a path containing 'zed-agent', so a broad command-line glob matches
        # the invoking shell and the helper kills itself before finishing teardown.
        $killed = @()
        try {
            $selfChain = [System.Collections.Generic.HashSet[int]]::new()
            $walk = $PID
            $guard = 0
            while ($walk -and $guard -lt 12) {
                [void]$selfChain.Add($walk)
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$walk" -ErrorAction SilentlyContinue
                if (-not $p -or -not $p.ParentProcessId -or $p.ParentProcessId -eq $walk) { break }
                $walk = [int]$p.ParentProcessId
                $guard++
            }

            Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue | ForEach-Object {
                if ($selfChain.Contains($_.Id)) { return }   # never kill self or an ancestor
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                # Match the watcher ENTRY SCRIPT, not a two-part wildcard over the
                # whole command line (which matched any pwsh running from zed-agent).
                if ($cmd -like "*Release-Watcher*") {
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                    $killed += $_.Id
                }
            }
        } catch {
            $errors += "kill watcher processes: $_"
        }
        return @{ success = $true; action = 'cleanup'; tasksRemoved = $removed; processesKilled = $killed; errors = $errors }
    }
}
