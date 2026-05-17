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

# Pre-create the log directory with an explicit Users:Modify ACE that
# inherits to files. Without this, bridge.log gets created the first time
# under whichever security context wrote first; if that's an admin (e.g. a
# manual elevated run), the file inherits Users:ReadAndExecute only and the
# scheduled task (which runs as BUILTIN\Users RunLevel=Limited) can't append
# -- Add-Content fails silently because the default $ErrorActionPreference
# in bridge.ps1's log function is Continue, and the bridge appears alive
# but produces zero log output.
$LogDir = Join-Path $env:ProgramData 'dualsense-xbridge'
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$acl = Get-Acl $LogDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Users', 'Modify',
    'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -Path $LogDir -AclObject $acl
Write-Host "Granted BUILTIN\Users Modify on $LogDir (inherits to bridge.log)"

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
