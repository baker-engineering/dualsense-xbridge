# build.ps1 -- produces DualSenseXBridge.msi from Product.wxs.
#
# Requirements:
#   WiX Toolset v3 (candle.exe + light.exe). Either on PATH, or installed
#   at the default location below.
#   Install: winget install WiXToolset.WiXToolset
#
# Usage:
#   cd dualsense-xbridge\installer
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#
# If your ExecutionPolicy is set to Restricted (the default for new accounts),
# either pass -ExecutionPolicy Bypass on the parent powershell.exe invocation
# as shown above, or change the policy for your account:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

$ErrorActionPreference = 'Stop'

# Resolve WiX. Prefer PATH; fall back to the default Programs Files install dir
# so users can build without manually editing PATH after `winget install`.
function Resolve-Wix {
    $onPath = Get-Command candle.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        return (Split-Path -Parent $onPath.Source)
    }
    $candidates = @(
        'C:\Program Files (x86)\WiX Toolset v3.14\bin',
        'C:\Program Files (x86)\WiX Toolset v3.11\bin',
        'C:\Program Files\WiX Toolset v3.14\bin'
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'candle.exe')) { return $c }
    }
    return $null
}

$wixBin = Resolve-Wix
if (-not $wixBin) {
    Write-Error "WiX v3 not found. Install with: winget install WiXToolset.WiXToolset  (default location: C:\Program Files (x86)\WiX Toolset v3.14\bin)"
    exit 1
}
$candle = Join-Path $wixBin 'candle.exe'
$light  = Join-Path $wixBin 'light.exe'
Write-Host "using WiX at: $wixBin"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    Write-Host "candle: Product.wxs -> Product.wixobj"
    & $candle -nologo Product.wxs -out Product.wixobj
    if ($LASTEXITCODE -ne 0) { throw "candle failed (exit $LASTEXITCODE)" }

    Write-Host "light:  Product.wixobj -> DualSenseXBridge.msi"
    & $light -nologo Product.wixobj -ext WixUtilExtension -out DualSenseXBridge.msi
    if ($LASTEXITCODE -ne 0) { throw "light failed (exit $LASTEXITCODE)" }

    Write-Host ""
    Write-Host "Build complete:"
    Get-Item DualSenseXBridge.msi | Select-Object Name, Length, LastWriteTime | Format-List

    Write-Host "SHA256 (use in winget manifest):"
    (Get-FileHash DualSenseXBridge.msi -Algorithm SHA256).Hash
} finally {
    Pop-Location
}
