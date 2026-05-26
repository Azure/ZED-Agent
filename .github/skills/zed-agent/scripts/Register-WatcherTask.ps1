function Register-ReleaseWatcherTask {
    param([string]$TaskName,[string]$Execute,[string]$Argument,[string]$WorkingDir,[string]$User,[string]$Description)
    $a = New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDir
    $tLogon = New-ScheduledTaskTrigger -AtLogOn -User $User
    # Recurring trigger: restart watcher every 30 minutes to survive sleep/lock/crash
    $tRecurring = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
    # Prefer MultipleInstances=StopExisting so each 30-min trigger can replace
    # a zombie watcher. Some Windows builds expose only Parallel/Queue/IgnoreNew,
    # so detect capability at runtime and fall back safely.
    $multipleInstances = 'StopExisting'
    try {
        [void][System.Enum]::Parse([Microsoft.PowerShell.Cmdletization.GeneratedTypes.ScheduledTask.MultipleInstancesEnum], $multipleInstances)
    } catch {
        $multipleInstances = 'IgnoreNew'
        Write-Warning "This host does not support MultipleInstances='StopExisting'; falling back to 'IgnoreNew'. Zombie watcher replacement is reduced on this OS."
    }

    # MultipleInstances=StopExisting (when supported): on each 30-min trigger,
    # kill any zombie watcher (e.g. frozen by hibernation) before starting a
    # fresh instance. Without this the default IgnoreNew can log 0x800710E0 and
    # silently drop the respawn while the zombie holds watcher.lock.
    # WakeToRun: ask Windows to wake from S3/S4 sleep to fire the trigger.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -WakeToRun -MultipleInstances $multipleInstances `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
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
        # Remove ALL ZED watcher tasks (current + any orphaned/stale from prior runs)
        $prefix = $cfg.operational.watcherTaskPrefix
        $removed = @()
        Get-ScheduledTask | Where-Object { $_.TaskName -like "$prefix*" } | ForEach-Object {
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
            $removed += $_.TaskName
        }
        # Kill any running watcher processes
        $killed = @()
        Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue | ForEach-Object {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
            if ($cmd -like "*Release-Watcher*" -or $cmd -like "*zed-agent*watcher*") {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                $killed += $_.Id
            }
        }
        return @{ success = $true; action = 'cleanup'; tasksRemoved = $removed; processesKilled = $killed }
    }
}
