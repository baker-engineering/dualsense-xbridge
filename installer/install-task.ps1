# install-task.ps1 — registers the DualSenseXBridge scheduled task.
# Called as a deferred CustomAction by the MSI installer.
#
# Task properties:
#   - Triggers at any user logon
#   - Runs as the interactive user (not SYSTEM) so the bridge inherits
#     the user's desktop session and can talk to ViGEmBus / HID
#   - Restarts automatically on failure with a 1-minute interval
#   - Hidden (no console window)

param(
    [Parameter(Mandatory=$true)][string] $InstallFolder
)

$ErrorActionPreference = 'Stop'

$TaskName = 'DualSenseXBridge'
$BridgePs1 = Join-Path $InstallFolder 'bridge.ps1'

if (-not (Test-Path $BridgePs1)) {
    Write-Error "bridge.ps1 not found at $BridgePs1"
    exit 1
}

# Remove any stale task by the same name before creating
Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | ForEach-Object {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BridgePs1`""

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0) `
    -Hidden

# Run as the interactive user (BUILTIN\Users), highest available privileges
# the user already has (no admin elevation needed for the bridge to talk to
# ViGEmBus, since the driver exposes a non-privileged client API).
$principal = New-ScheduledTaskPrincipal `
    -GroupId 'S-1-5-32-545' `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'DualSense -> ViGEm X360 bridge (DualSense XBridge)'

Write-Host "Registered scheduled task '$TaskName' running $BridgePs1"
exit 0
