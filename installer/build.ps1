# build.ps1 — produces DualSenseXBridge.msi from Product.wxs.
#
# Requirements:
#   WiX Toolset v3 on PATH (candle.exe + light.exe)
#   Install: winget install WixToolset.Wix
#
# Usage:
#   cd C:\Users\force\dualsense-xbridge\installer
#   .\build.ps1

$ErrorActionPreference = 'Stop'

$candle = Get-Command candle.exe -ErrorAction SilentlyContinue
$light  = Get-Command light.exe  -ErrorAction SilentlyContinue
if (-not $candle -or -not $light) {
    Write-Error "WiX v3 not found on PATH. Install via 'winget install WixToolset.Wix' (you may need to add the install directory to PATH manually -- typical location: C:\Program Files (x86)\WiX Toolset v3.14\bin)."
    exit 1
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    Write-Host "candle: Product.wxs -> Product.wixobj"
    & $candle.Source -nologo Product.wxs -out Product.wixobj
    if ($LASTEXITCODE -ne 0) { throw "candle failed (exit $LASTEXITCODE)" }

    Write-Host "light:  Product.wixobj -> DualSenseXBridge.msi"
    & $light.Source -nologo Product.wixobj -ext WixUtilExtension -out DualSenseXBridge.msi
    if ($LASTEXITCODE -ne 0) { throw "light failed (exit $LASTEXITCODE)" }

    Write-Host ""
    Write-Host "Build complete:"
    Get-Item DualSenseXBridge.msi | Select-Object Name, Length, LastWriteTime | Format-List

    Write-Host "SHA256 (use in winget manifest):"
    (Get-FileHash DualSenseXBridge.msi -Algorithm SHA256).Hash
} finally {
    Pop-Location
}
