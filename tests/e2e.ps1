# e2e.ps1 -- end-to-end test runner for dualsense-xbridge.
#
# For each fixture in tests/fixtures/, start bridge.ps1 in stub mode against
# the fixture, scan XInput slots 0..3 for the one whose state matches the
# fixture's expected values, then assert. Exit 0 on full pass, 1 on any fail.
#
# Designed for a clean CI runner where the test bridge will land on slot 0
# each iteration. On a dev box where another bridge already owns a slot the
# matching strategy still works as long as the fixtures are state-distinct
# from whatever the resident bridge is doing -- the neutral fixture is the
# only one that can collide with an idle resident bridge.
#
# Requirements:
#   - ViGEmBus driver installed
#   - xinput1_4.dll available (Win10+)
#   - src/vigemclient.x64.dll alongside src/bridge.ps1
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tests/e2e.ps1
#   powershell -ExecutionPolicy Bypass -File tests/e2e.ps1 -BridgePs1 path\to\bridge.ps1

[CmdletBinding()]
param(
    [string] $BridgePs1   = (Join-Path $PSScriptRoot '..\src\bridge.ps1'),
    [string] $FixtureDir  = (Join-Path $PSScriptRoot 'fixtures'),
    [int]    $WarmupMs    = 1500,
    [int]    $MatchScanMs = 3000
)

$ErrorActionPreference = 'Stop'

# --- XInput PInvoke --------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class XInput {
    [DllImport("xinput1_4.dll")]
    public static extern int XInputGetState(int dwUserIndex, ref XINPUT_STATE pState);
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_GAMEPAD {
        public ushort wButtons;
        public byte   bLeftTrigger;
        public byte   bRightTrigger;
        public short  sThumbLX;
        public short  sThumbLY;
        public short  sThumbRX;
        public short  sThumbRY;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_STATE {
        public uint           dwPacketNumber;
        public XINPUT_GAMEPAD Gamepad;
    }
}
"@

function Read-XInputState([int]$slot) {
    $state = New-Object XInput+XINPUT_STATE
    $rc = [XInput]::XInputGetState($slot, [ref]$state)
    return @{ rc = $rc; state = $state }
}

function Compare-Gamepad($actual, $expected) {
    $mismatches = @()
    foreach ($k in $expected.Keys) {
        $a = $actual.$k
        $e = $expected[$k]
        if ($a -ne $e) {
            $mismatches += ("{0}: actual={1} expected={2}" -f $k, $a, $e)
        }
    }
    return $mismatches
}

# Scan all XInput slots looking for one whose state exactly matches
# $expected. Returns @{ slot=N; state=... } on match, or $null on timeout.
function Find-MatchingSlot($expected, [int]$timeoutMs, [scriptblock]$extraCheck = $null) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    $lastSnapshot = @{}
    while ((Get-Date) -lt $deadline) {
        for ($i = 0; $i -lt 4; $i++) {
            $r = Read-XInputState $i
            if ($r.rc -ne 0) { continue }
            $mm = Compare-Gamepad $r.state.Gamepad $expected
            $extraOk = $true
            if ($extraCheck) {
                $extraOk = & $extraCheck $r.state.Gamepad
            }
            if ($mm.Count -eq 0 -and $extraOk) {
                return @{ slot = $i; state = $r.state }
            }
            $lastSnapshot[$i] = $r.state.Gamepad
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Format-Expected($e) {
    $parts = @()
    if ($e.ContainsKey('wButtons'))      { $parts += ("wButtons=0x{0:X4}" -f $e.wButtons) }
    if ($e.ContainsKey('sThumbLX'))      { $parts += "LX=$($e.sThumbLX)" }
    if ($e.ContainsKey('sThumbLY'))      { $parts += "LY=$($e.sThumbLY)" }
    if ($e.ContainsKey('sThumbRX'))      { $parts += "RX=$($e.sThumbRX)" }
    if ($e.ContainsKey('sThumbRY'))      { $parts += "RY=$($e.sThumbRY)" }
    if ($e.ContainsKey('bLeftTrigger'))  { $parts += "LT=$($e.bLeftTrigger)" }
    if ($e.ContainsKey('bRightTrigger')) { $parts += "RT=$($e.bRightTrigger)" }
    return ($parts -join ' ')
}

# --- Test cases ------------------------------------------------------------
# XInput button bits:
#   0x0001 DPAD_UP      0x0002 DPAD_DOWN    0x0004 DPAD_LEFT    0x0008 DPAD_RIGHT
#   0x0010 START        0x0020 BACK         0x0040 LEFT_THUMB   0x0080 RIGHT_THUMB
#   0x0100 LEFT_SHOULDER 0x0200 RIGHT_SHOULDER 0x0400 GUIDE
#   0x1000 A            0x2000 B            0x4000 X            0x8000 Y

$cases = @(
    @{ fixture = 'neutral.bin';        expected = @{ wButtons = 0;       sThumbLX = 0;     sThumbLY = 0;     bLeftTrigger = 0;   bRightTrigger = 0 } }
    @{ fixture = 'a_pressed.bin';      expected = @{ wButtons = 0x1000 } }
    @{ fixture = 'b_pressed.bin';      expected = @{ wButtons = 0x2000 } }
    @{ fixture = 'x_pressed.bin';      expected = @{ wButtons = 0x4000 } }
    @{ fixture = 'y_pressed.bin';      expected = @{ wButtons = 0x8000 } }
    @{ fixture = 'start_pressed.bin';  expected = @{ wButtons = 0x0010 } }
    # NOTE: guide_pressed.bin is intentionally not in the test set. The
    # bridge correctly pushes wButtons=0x0400 to ViGEm, but XInputGetState
    # masks the GUIDE bit -- you have to call the undocumented
    # XInputGetStateEx (ordinal 100 in xinput1_4.dll) to see it. Fixture
    # is shipped so users can exercise the path manually if they care.
    @{ fixture = 'dpad_up.bin';        expected = @{ wButtons = 0x0001 } }
    # LX raw 0 -> (0-128)*257 = -32896, clamped to int16 min -32768 by bridge.
    @{ fixture = 'lstick_left.bin';    expected = @{ wButtons = 0; sThumbLX = -32768 } }
    @{ fixture = 'lt_full.bin';        expected = @{ wButtons = 0; bLeftTrigger = 255; bRightTrigger = 0 } }
)

# --- Test loop -------------------------------------------------------------
$bridgePs1Full = (Resolve-Path $BridgePs1).Path
$fixtureDirFull = (Resolve-Path $FixtureDir).Path
Write-Host "bridge:   $bridgePs1Full"
Write-Host "fixtures: $fixtureDirFull"
Write-Host ""

$pass = 0
$fail = 0
$failures = @()

foreach ($case in $cases) {
    $fixturePath = Join-Path $fixtureDirFull $case.fixture
    if (-not (Test-Path $fixturePath)) {
        Write-Host ("[SKIP] {0}: fixture missing" -f $case.fixture)
        continue
    }

    Write-Host -NoNewline ("[RUN ] {0,-22} " -f $case.fixture)

    $proc = Start-Process powershell `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $bridgePs1Full,
            '-StubReportFile', $fixturePath
        ) -WindowStyle Hidden -PassThru

    try {
        Start-Sleep -Milliseconds $WarmupMs

        $match = Find-MatchingSlot $case.expected $MatchScanMs

        if (-not $match) {
            # Dump what we DID see on each slot for diagnostics
            Write-Host "FAIL: no slot matched expected state"
            Write-Host ("       expected: {0}" -f (Format-Expected $case.expected))
            for ($i = 0; $i -lt 4; $i++) {
                $r = Read-XInputState $i
                if ($r.rc -eq 0) {
                    $g = $r.state.Gamepad
                    Write-Host ("       slot {0}: wButtons=0x{1:X4} LX={2} LY={3} LT={4} RT={5} pkt={6}" -f $i, $g.wButtons, $g.sThumbLX, $g.sThumbLY, $g.bLeftTrigger, $g.bRightTrigger, $r.state.dwPacketNumber)
                } else {
                    Write-Host ("       slot {0}: not connected (rc=0x{1:X})" -f $i, $r.rc)
                }
            }
            $fail++
            $failures += $case.fixture
            continue
        }

        Write-Host ("PASS [slot {0}] {1}" -f $match.slot, (Format-Expected $case.expected))
        $pass++
    } finally {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        # Also kill any child powershell that survived the wrapper -- some
        # Start-Process invocations spawn a host that holds the script's
        # process group, and the bridge does not respond to Stop-Process
        # on the wrapper alone.
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*-StubReportFile*$($case.fixture)*" } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
        # Pause so ViGEm can reclaim the slot before the next case plugs another.
        # 2s is reliable on windows-latest runners; bump if local runs see slot
        # exhaustion (XInput supports max 4 controllers).
        Start-Sleep -Milliseconds 2000
    }
}

Write-Host ""
Write-Host ("=== Results: {0} passed, {1} failed ===" -f $pass, $fail)
if ($fail -gt 0) {
    Write-Host "failed fixtures:"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
exit 0
