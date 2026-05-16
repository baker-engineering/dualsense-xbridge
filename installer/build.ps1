# build.ps1 -- produces DualSenseXBridge-<arch>.msi from Product.wxs.
#
# Requirements:
#   WiX Toolset v3 (candle.exe + light.exe). Either on PATH, or installed
#   at the default location below.
#   Install: winget install WiXToolset.WiXToolset
#
# Usage:
#   cd dualsense-xbridge\installer
#   powershell -ExecutionPolicy Bypass -File .\build.ps1               # x64 (default)
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Arch arm64   # arm64
#
# The build expects src\vigemclient.<arch>.dll alongside src\bridge.ps1.
# x64 is vendored; arm64 is built from source by CI (build-deps job).
#
# If your ExecutionPolicy is set to Restricted (the default for new accounts),
# either pass -ExecutionPolicy Bypass on the parent powershell.exe invocation
# as shown above, or change the policy for your account:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

param(
    [ValidateSet('x64','arm64')]
    [string] $Arch = 'x64'
)

$ErrorActionPreference = 'Stop'

# Resolve WiX. Prefer PATH; fall back to the default Program Files install dir
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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$dll = Join-Path $repoRoot "src\vigemclient.$Arch.dll"
if (-not (Test-Path $dll)) {
    Write-Error "Missing native DLL: $dll  (for x64 this is vendored; for arm64 CI's build-deps job produces it from source)"
    exit 1
}

Write-Host "arch:   $Arch"
Write-Host "wix:    $wixBin"
Write-Host "dll:    $dll"

$msiName = "DualSenseXBridge-$Arch.msi"

Push-Location $here
try {
    Write-Host "candle: Product.wxs -> Product.wixobj"
    & $candle -nologo -arch $Arch Product.wxs -out Product.wixobj
    if ($LASTEXITCODE -ne 0) { throw "candle failed (exit $LASTEXITCODE)" }

    Write-Host "light:  Product.wixobj -> $msiName"
    & $light -nologo Product.wixobj -ext WixUtilExtension -out $msiName
    if ($LASTEXITCODE -ne 0) { throw "light failed (exit $LASTEXITCODE)" }

    Write-Host ""
    Write-Host "Build complete:"
    Get-Item $msiName | Select-Object Name, Length, LastWriteTime | Format-List

    Write-Host "SHA256 (use in winget manifest):"
    (Get-FileHash $msiName -Algorithm SHA256).Hash
} finally {
    Pop-Location
}
