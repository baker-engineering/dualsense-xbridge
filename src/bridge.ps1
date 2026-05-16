# dualsense-xbridge
# Reads HID input reports from the BBB-emulated DualSense gadget
# (VID 054C, PID 0CE6) and pushes them to a virtual Xbox 360 controller via
# ViGEmBus, so games see a stock X360 controller.
#
# Distributable v1.1.0:
#  - DLL loaded relative to script (no Costura temp-path dependency)
#  - DualSense device-instance-id discovered at runtime (no hardcoded port)
#  - Log directory chosen at runtime (ProgramData if writable, else script dir)
#  - Forever-loop with 500 ms reconnect on transient failures

# --- Path resolution -------------------------------------------------------

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

# Log path: prefer %ProgramData%\dualsense-xbridge\, fall back to script dir.
$LogDirCandidate = Join-Path $env:ProgramData 'dualsense-xbridge'
try {
    if (-not (Test-Path $LogDirCandidate)) {
        New-Item -ItemType Directory -Path $LogDirCandidate -Force -ErrorAction Stop | Out-Null
    }
    # Probe write access
    $probe = Join-Path $LogDirCandidate '.writeprobe'
    Set-Content -Path $probe -Value 'ok' -ErrorAction Stop
    Remove-Item $probe -ErrorAction SilentlyContinue
    $LogDir = $LogDirCandidate
} catch {
    $LogDir = $ScriptDir
}
$LOG = Join-Path $LogDir 'bridge.log'

# --- Tell the loader where vigemclient.dll lives ---------------------------
# vigemclient.dll sits alongside this script. SetDllDirectory adds that
# path to the native loader's search order so DllImport calls in the [VG]
# type below resolve to it without a hardcoded absolute path.

Add-Type -Namespace DualSenseXBridge -Name NativeLoader -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern bool SetDllDirectory(string lpPathName);
"@
[DualSenseXBridge.NativeLoader]::SetDllDirectory($ScriptDir) | Out-Null

# --- P/Invoke surface ------------------------------------------------------

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class VG {
    const string DLL = "vigemclient.dll";
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr vigem_alloc();
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int vigem_connect(IntPtr vigem);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr vigem_target_x360_alloc();
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int vigem_target_add(IntPtr vigem, IntPtr target);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int vigem_target_x360_update(IntPtr vigem, IntPtr target, XUSB_REPORT report);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int vigem_target_remove(IntPtr vigem, IntPtr target);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void vigem_target_free(IntPtr target);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void vigem_disconnect(IntPtr vigem);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void vigem_free(IntPtr vigem);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern int vigem_target_get_index(IntPtr target);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct XUSB_REPORT {
        public ushort wButtons;
        public byte bLeftTrigger;
        public byte bRightTrigger;
        public short sThumbLX;
        public short sThumbLY;
        public short sThumbRX;
        public short sThumbRY;
    }
}

public class K {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr sa, uint disp, uint flags, IntPtr template);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern void HidD_GetHidGuid(out Guid guid);
}
"@

# --- Configuration ---------------------------------------------------------

# VID/PID of the BBB-emulated DualSense gadget. (Real DualSense uses the same
# VID/PID — if a real one is plugged in, the bridge may grab whichever
# enumerates first.)
$DS_VID = '054C'
$DS_PID = '0CE6'
$VIGEM_OK = 0x20000000

function Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz') $msg" | Add-Content $LOG
}

# DPad: lower nibble of byte 8: 0=N 1=NE 2=E 3=SE 4=S 5=SW 6=W 7=NW 8=Released
$dpadMap = @{
  0 = 0x0001                       # UP
  1 = 0x0001 -bor 0x0008           # UP+RIGHT
  2 = 0x0008                       # RIGHT
  3 = 0x0008 -bor 0x0002           # RIGHT+DOWN
  4 = 0x0002                       # DOWN
  5 = 0x0002 -bor 0x0004           # DOWN+LEFT
  6 = 0x0004                       # LEFT
  7 = 0x0004 -bor 0x0001           # LEFT+UP
  8 = 0                            # Released
}

# Discover the current HID device-instance-id for the DualSense gadget by
# querying PnP for HID class entries matching the VID/PID. The instance id
# embeds the USB port, so it differs per machine and per replug; we look it
# up on every connect rather than baking a value in.
function Find-DualSenseInstanceId {
    $pattern = "HID\VID_${DS_VID}&PID_${DS_PID}\*"
    $dev = Get-PnpDevice -PresentOnly -Class HIDClass -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceId -like $pattern -and $_.Status -eq 'OK' } |
           Select-Object -First 1
    if (-not $dev) { throw "DualSense ($DS_VID:$DS_PID) not present or not OK" }
    return $dev.InstanceId
}

function Open-DualSense {
    $instance = Find-DualSenseInstanceId
    $g = [Guid]::Empty
    [K]::HidD_GetHidGuid([ref]$g) | Out-Null
    $sym = "\\?\hid#" + ($instance.Substring(4).ToLower() -replace "\\","#") + "#{" + $g.ToString() + "}"
    $h = [K]::CreateFile($sym, [System.Convert]::ToUInt32("C0000000",16), [uint32]3, [IntPtr]::Zero, [uint32]3, [System.Convert]::ToUInt32("40000000",16), [IntPtr]::Zero)
    if ($h.IsInvalid) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "cannot open DualSense, err=$err"
    }
    return $h
}

# Plug a virtual X360 target. vigem_target_get_index() returns ViGEm's
# internal target-array index, NOT the XInput user index — real XInput
# delivery goes to whichever slot Windows assigns next.
function Plug-X360($client) {
    $target = [VG]::vigem_target_x360_alloc()
    $rc = [VG]::vigem_target_add($client, $target)
    if ($rc -ne $VIGEM_OK) {
        [VG]::vigem_target_free($target)
        throw ("vigem_target_add rc=0x{0:X8}" -f $rc)
    }
    $idx = [VG]::vigem_target_get_index($target)
    Log "PLUG vigem-idx=$idx"
    return @{ Target = $target; Index = $idx }
}

function Run-Bridge {
    $h = $null; $fs = $null; $client = $null; $target = $null
    try {
        $h = Open-DualSense
        $fs = New-Object System.IO.FileStream($h, [System.IO.FileAccess]::ReadWrite, 64, $true)

        $client = [VG]::vigem_alloc()
        $rc = [VG]::vigem_connect($client)
        if ($rc -ne $VIGEM_OK) {
            throw ("vigem_connect rc=0x{0:X8}" -f $rc)
        }

        $plug = Plug-X360 $client
        $target = $plug.Target
        $idx = $plug.Index

        Log "START vigem-idx=$idx"

        $report = New-Object VG+XUSB_REPORT
        $count = 0
        $pushes = 0
        $lastHeartbeat = Get-Date

        while ($true) {
            $buf = New-Object byte[] 64
            $task = $fs.ReadAsync($buf, 0, 64, [System.Threading.CancellationToken]::None)
            try { $task.Wait() } catch { throw "ReadAsync exception: $($_.Exception.Message)" }
            if ($task.IsFaulted) { throw "ReadAsync faulted" }
            if ($task.Result -lt 11) { throw "short read len=$($task.Result)" }
            $count++

            $report.sThumbLX = [int16](([int]$buf[1] - 128) * 257)
            $report.sThumbLY = [int16](((128 - [int]$buf[2])) * 257)
            $report.sThumbRX = [int16](([int]$buf[3] - 128) * 257)
            $report.sThumbRY = [int16](((128 - [int]$buf[4])) * 257)
            $report.bLeftTrigger = $buf[5]
            $report.bRightTrigger = $buf[6]

            $btn = 0
            $b8 = $buf[8]; $b9 = $buf[9]; $b10 = $buf[10]
            $dpadCode = $b8 -band 0x0F
            if ($dpadMap.ContainsKey($dpadCode)) { $btn = $btn -bor $dpadMap[$dpadCode] }
            if ($b8 -band 0x10) { $btn = $btn -bor 0x4000 }  # Square -> X
            if ($b8 -band 0x20) { $btn = $btn -bor 0x1000 }  # Cross -> A
            if ($b8 -band 0x40) { $btn = $btn -bor 0x2000 }  # Circle -> B
            if ($b8 -band 0x80) { $btn = $btn -bor 0x8000 }  # Triangle -> Y
            if ($b9 -band 0x01) { $btn = $btn -bor 0x0100 }  # L1 -> LB
            if ($b9 -band 0x02) { $btn = $btn -bor 0x0200 }  # R1 -> RB
            if ($b9 -band 0x10) { $btn = $btn -bor 0x0020 }  # Share -> BACK
            if ($b9 -band 0x20) { $btn = $btn -bor 0x0010 }  # Options -> START
            if ($b9 -band 0x40) { $btn = $btn -bor 0x0040 }  # L3 -> LEFT_THUMB
            if ($b9 -band 0x80) { $btn = $btn -bor 0x0080 }  # R3 -> RIGHT_THUMB
            if ($b10 -band 0x01) { $btn = $btn -bor 0x0400 }  # PS -> GUIDE
            $report.wButtons = [uint16]$btn

            $rc = [VG]::vigem_target_x360_update($client, $target, $report)
            if ($rc -eq $VIGEM_OK) { $pushes++ }

            # Heartbeat once per 30s
            if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 30) {
                Log "tick count=$count pushes=$pushes vigem-idx=$idx"
                $lastHeartbeat = Get-Date
            }
        }
    }
    finally {
        if ($target) {
            try { [VG]::vigem_target_remove($client, $target) | Out-Null } catch {}
            [VG]::vigem_target_free($target)
        }
        if ($client) {
            try { [VG]::vigem_disconnect($client) } catch {}
            [VG]::vigem_free($client)
        }
        if ($fs) { $fs.Dispose() }
        if ($h)  { $h.Dispose() }
    }
}

# Forever loop: relaunch on any failure with 500 ms backoff so the bridge
# survives transient DualSense replugs, BBB-side daemon restarts, mode
# switches, ViGEm hiccups.
Log "BOOT pid=$PID forever-mode script=$ScriptDir log=$LOG"
while ($true) {
    try {
        Run-Bridge
        Log "Run-Bridge returned without exception; restarting in 500ms"
    } catch {
        Log "ERROR: $($_.Exception.Message); restarting in 500ms"
    }
    Start-Sleep -Milliseconds 500
}
