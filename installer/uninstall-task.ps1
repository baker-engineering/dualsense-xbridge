# uninstall-task.ps1 — removes the DualSenseXBridge scheduled task and
# terminates any running bridge.ps1 instance.
# Called as a deferred CustomAction by the MSI uninstaller.

$ErrorActionPreference = 'Continue'

$TaskName = 'DualSenseXBridge'

# Stop and unregister the scheduled task
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered scheduled task '$TaskName'"
}

# Kill any running bridge.ps1 processes (their PIDs aren't tracked anywhere
# else, so we match on command line)
$bridgeProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*bridge.ps1*' }

foreach ($p in $bridgeProcs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped bridge PID $($p.ProcessId)"
    } catch {}
}

exit 0
