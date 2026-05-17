# make-fixture.ps1 -- builds a 64-byte DualSense input HID report fixture.
#
# Usage:
#   .\make-fixture.ps1 -OutFile out.bin                  # all neutral
#   .\make-fixture.ps1 -OutFile a.bin -Cross             # A button pressed
#   .\make-fixture.ps1 -OutFile combo.bin -Cross -LX 0   # A + left stick full left
#
# Byte layout (matches what src/bridge.ps1 decodes):
#   byte[0]    report id (0x01 for DualSense input)
#   byte[1]    left stick X     (0=full left, 128=center, 255=full right)
#   byte[2]    left stick Y     (0=full up,   128=center, 255=full down)
#   byte[3]    right stick X
#   byte[4]    right stick Y
#   byte[5]    left trigger     (0..255)
#   byte[6]    right trigger    (0..255)
#   byte[7]    report counter   (don't care for tests)
#   byte[8]    dpad nibble (0=N,1=NE,2=E,3=SE,4=S,5=SW,6=W,7=NW,8=Released)
#              | 0x10 Square    | 0x20 Cross    | 0x40 Circle    | 0x80 Triangle
#   byte[9]    | 0x01 L1        | 0x02 R1       | 0x10 Share     | 0x20 Options
#              | 0x40 L3        | 0x80 R3
#   byte[10]   | 0x01 PS        (touchpad/IMU follow but bridge ignores them)
#
# All -Switch flags default off; sticks default 128 (center); triggers default 0;
# dpad defaults to 8 (released).

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $OutFile,

    # Sticks 0..255, 128 = center
    [ValidateRange(0,255)][int] $LX = 128,
    [ValidateRange(0,255)][int] $LY = 128,
    [ValidateRange(0,255)][int] $RX = 128,
    [ValidateRange(0,255)][int] $RY = 128,

    # Triggers 0..255
    [ValidateRange(0,255)][int] $LT = 0,
    [ValidateRange(0,255)][int] $RT = 0,

    # Dpad direction: 0=N 1=NE 2=E 3=SE 4=S 5=SW 6=W 7=NW 8=Released
    [ValidateRange(0,8)][int] $Dpad = 8,

    # Face buttons (DualSense names; bridge maps to XInput A/B/X/Y)
    [switch] $Square,        # -> XInput X
    [switch] $Cross,         # -> XInput A
    [switch] $Circle,        # -> XInput B
    [switch] $Triangle,      # -> XInput Y

    # Shoulders / sticks / system
    [switch] $L1,            # -> XInput LB
    [switch] $R1,            # -> XInput RB
    [switch] $Share,         # -> XInput BACK
    [switch] $Options,       # -> XInput START
    [switch] $L3,            # -> XInput LEFT_THUMB
    [switch] $R3,            # -> XInput RIGHT_THUMB
    [switch] $PS             # -> XInput GUIDE
)

$buf = New-Object byte[] 64
$buf[0]  = 0x01
$buf[1]  = [byte]$LX
$buf[2]  = [byte]$LY
$buf[3]  = [byte]$RX
$buf[4]  = [byte]$RY
$buf[5]  = [byte]$LT
$buf[6]  = [byte]$RT
$buf[7]  = 0

$b8 = [byte]($Dpad -band 0x0F)
if ($Square)   { $b8 = $b8 -bor 0x10 }
if ($Cross)    { $b8 = $b8 -bor 0x20 }
if ($Circle)   { $b8 = $b8 -bor 0x40 }
if ($Triangle) { $b8 = $b8 -bor 0x80 }
$buf[8] = $b8

$b9 = [byte]0
if ($L1)      { $b9 = $b9 -bor 0x01 }
if ($R1)      { $b9 = $b9 -bor 0x02 }
if ($Share)   { $b9 = $b9 -bor 0x10 }
if ($Options) { $b9 = $b9 -bor 0x20 }
if ($L3)      { $b9 = $b9 -bor 0x40 }
if ($R3)      { $b9 = $b9 -bor 0x80 }
$buf[9] = $b9

$b10 = [byte]0
if ($PS) { $b10 = $b10 -bor 0x01 }
$buf[10] = $b10

[System.IO.File]::WriteAllBytes($OutFile, $buf)
Write-Host ("wrote $OutFile ({0} bytes)" -f $buf.Length)
Write-Host ("  byte[8] = 0x{0:X2}  byte[9] = 0x{1:X2}  byte[10] = 0x{2:X2}" -f $b8, $b9, $b10)
Write-Host ("  LX={0} LY={1} RX={2} RY={3} LT={4} RT={5} Dpad={6}" -f $LX, $LY, $RX, $RY, $LT, $RT, $Dpad)
