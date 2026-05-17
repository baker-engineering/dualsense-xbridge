# perf.ps1 -- sustained processing-rate test for the bridge.
#
# Starts bridge.ps1 in stub mode with -MaxReports N. The bridge processes
# N reports as fast as it can (stub MemoryStream has no I/O wait), logs a
# "PERF total_reports=N pushes=M elapsed_ms=… rate=…Hz" line, then exits 0.
# We parse the line and assert the sustained rate clears MinRateHz.
#
# Why this catches regressions: the BBB sends reports at 1 kHz. If the
# bridge's PowerShell+P/Invoke per-iter overhead rises so high that it
# can't comfortably outpace 1 kHz, real-time pushing falls behind. The
# stub mode strips I/O wait so we measure the pure-overhead floor.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tests/perf.ps1
#   powershell -ExecutionPolicy Bypass -File tests/perf.ps1 -MaxReports 10000 -MinRateHz 1000

[CmdletBinding()]
param(
    [string] $BridgePs1   = (Join-Path $PSScriptRoot '..\src\bridge.ps1'),
    [string] $Fixture     = (Join-Path $PSScriptRoot 'fixtures\neutral.bin'),
    [int]    $MaxReports  = 5000,
    [int]    $TimeoutSec  = 30,
    [double] $MinRateHz   = 500
)

$ErrorActionPreference = 'Stop'

$bridgeFull  = (Resolve-Path $BridgePs1).Path
$fixtureFull = (Resolve-Path $Fixture).Path
$log = Join-Path $env:ProgramData 'dualsense-xbridge\bridge.log'

# Wipe the log so we know our PERF line is the latest one (the live bridge,
# if any, will keep appending; we want our run's line specifically).
if (Test-Path $log) {
    Set-Content -Path $log -Value '' -NoNewline
}

Write-Host "bridge:    $bridgeFull"
Write-Host "fixture:   $fixtureFull"
Write-Host "reports:   $MaxReports"
Write-Host "timeout:   ${TimeoutSec}s"
Write-Host "floor:     $MinRateHz Hz"
Write-Host ""

$proc = Start-Process powershell -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $bridgeFull,
    '-StubReportFile', $fixtureFull,
    '-MaxReports', "$MaxReports"
) -WindowStyle Hidden -PassThru

# Wait for clean exit (bridge logs PERF then exits 0)
try {
    $proc | Wait-Process -Timeout $TimeoutSec -ErrorAction Stop
} catch {
    Write-Host "FAIL: bridge did not exit within ${TimeoutSec}s for $MaxReports reports"
    try { Stop-Process -Id $proc.Id -Force } catch {}
    if (Test-Path $log) {
        Write-Host "---bridge.log tail---"
        Get-Content $log -Tail 15
    }
    exit 1
}

# Parse the PERF line
$perfLine = $null
if (Test-Path $log) {
    $perfLine = Get-Content $log | Where-Object { $_ -match 'PERF total_reports=' } | Select-Object -Last 1
}
if (-not $perfLine) {
    Write-Host "FAIL: no PERF line in bridge.log after bridge exited"
    Write-Host "---bridge.log tail---"
    if (Test-Path $log) { Get-Content $log -Tail 20 }
    exit 1
}
Write-Host "PERF line: $perfLine"

if ($perfLine -notmatch 'total_reports=(\d+) pushes=(\d+) elapsed_ms=([\d.]+) rate=([\d.]+)Hz') {
    Write-Host "FAIL: could not parse PERF line"
    exit 1
}
$reports   = [int]$matches[1]
$pushes    = [int]$matches[2]
$elapsedMs = [double]$matches[3]
$rate      = [double]$matches[4]

Write-Host ""
Write-Host ("results: {0} reports, {1} pushes, {2:F1} ms elapsed, {3:F1} Hz sustained" -f $reports, $pushes, $elapsedMs, $rate)

# Sanity: reports actually reached the requested count (within +/- 5)
if ($reports -lt ($MaxReports - 5)) {
    Write-Host "FAIL: bridge exited at $reports reports, expected $MaxReports"
    exit 1
}

# Sanity: pushes vs reports. Every report should produce a successful
# vigem_target_x360_update. Allow a few stragglers.
if ($pushes -lt ($reports - 5)) {
    Write-Host "FAIL: pushes=$pushes lags reports=$reports by more than 5"
    exit 1
}

# Real assertion: sustained rate must clear MinRateHz
if ($rate -lt $MinRateHz) {
    Write-Host ("FAIL: sustained rate {0:F1} Hz is below floor {1} Hz" -f $rate, $MinRateHz)
    exit 1
}

Write-Host ("OK: rate {0:F1} Hz >= floor {1} Hz" -f $rate, $MinRateHz)
exit 0
