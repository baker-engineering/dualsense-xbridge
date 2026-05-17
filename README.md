# DualSense XBridge

[![CI](https://github.com/baker-engineering/dualsense-xbridge/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/baker-engineering/dualsense-xbridge/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/baker-engineering/dualsense-xbridge?label=release)](https://github.com/baker-engineering/dualsense-xbridge/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Project home:** https://github.com/baker-engineering/dualsense-xbridge
| **License:** MIT | **Releases:** [GitHub Releases](https://github.com/baker-engineering/dualsense-xbridge/releases)

A Windows-side translator that reads HID input reports from a
DualSense-class USB device and re-emits them as a virtual Xbox 360
controller via [ViGEmBus](https://github.com/nefarius/ViGEmBus).
The game sees a stock Xbox 360 controller (aim-assist, deadbands, the
works); the upstream gadget sees nothing change.

Designed as the Windows companion for **custom DualSense-emulating HID
gadgets** — typically a Linux board (BeagleBone, Raspberry Pi, etc.)
running a FunctionFS gadget that presents as VID `054C` / PID `0CE6`
while the user actually drives it with keyboard + mouse, a touchscreen,
or any other input source.

It's deliberately small: one PowerShell file (~250 lines) plus
`vigemclient.dll`, no GUI, no profiles, no lightbar / battery /
motion semantics. If you want a feature-rich DualSense driver for a
real Sony controller, use
[DS4Windows](https://github.com/Ryochan7/DS4Windows). If you want a
stateless translator that disappears into a scheduled task and feeds
XInput at 1 kHz, this is it.

## Who this is for

- People building **custom HID gadgets that emulate a DualSense** and
  need a Windows-side companion to expose the gadget as Xbox 360 input.
- People who want **`winget install …`** to be the complete install
  story: the manifest pulls ViGEmBus and HidHide as dependencies, the
  MSI registers a scheduled task, and there's nothing else to wire up.
- Specifically, the **Call of Duty: Warzone** use case — driving a
  keyboard+mouse-fed gadget while the game applies controller-class
  behavior. See [QUICKSTART.md](QUICKSTART.md) for the ~10-minute
  end-user setup.

## Who this is **not** for

- Real-DualSense users (use DS4Windows — better motion / lightbar /
  battery support).
- Anyone who wants remappable profiles or a GUI (use
  [reWASD](https://www.rewasd.com/) or DS4Windows).
- Linux gaming (Steam Input handles native DualSense natively).

The rest of this README is for developers and packagers — layout, how
to build the MSI locally, how to publish a release. End users should
read [QUICKSTART.md](QUICKSTART.md) instead.

## Layout

```
dualsense-xbridge/
├── src/
│   ├── bridge.ps1            refactored bridge (no hardcoded paths, dynamic DS instance lookup)
│   └── vigemclient.dll       native ViGEm client lib (175 KB, x64)
├── installer/
│   ├── Product.wxs           WiX v3 source
│   ├── install-task.ps1      registers DualSenseXBridge scheduled task (called by MSI)
│   ├── uninstall-task.ps1    removes the task + kills running bridge (called by MSI)
│   ├── bridge-task.xml       reference schtasks XML (not used by MSI, for manual import)
│   └── build.ps1             candle + light orchestration
└── manifests/
    ├── BakerEngineering.DualSenseXBridge.installer.yaml
    ├── BakerEngineering.DualSenseXBridge.locale.en-US.yaml
    └── BakerEngineering.DualSenseXBridge.yaml
```

## Build the MSI

```powershell
winget install WixToolset.Wix    # one-time
cd installer
.\build.ps1
```

Output: `DualSenseXBridge.msi` + a SHA256 string for the winget manifest.

## Test install (local, no public submission)

```powershell
# As admin, in the manifests/ folder:
winget install --manifest .
```

For this to work locally, edit `BakerEngineering.DualSenseXBridge.installer.yaml`:
1. Set `InstallerUrl:` to a local `file://` URL OR upload the MSI to your fileserver
   and use the http URL (e.g. `http://192.168.1.5:8766/DualSenseXBridge.msi`).
2. Replace `InstallerSha256:` with the SHA256 emitted by `build.ps1`.

## Publish to the public winget repo

1. Get an Authenticode code-signing certificate; sign the MSI:
   ```
   signtool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /a DualSenseXBridge.msi
   ```
2. Host the signed MSI somewhere stable (GitHub Releases works well).
3. Set the real URL + SHA256 in `BakerEngineering.DualSenseXBridge.installer.yaml`.
4. Fork `microsoft/winget-pkgs`, add manifests under
   `manifests/b/BakerEngineering/DualSenseXBridge/<version>/`, open a PR.

## What the MSI does on install

1. Copies `bridge.ps1` and `vigemclient.dll` to
   `%ProgramFiles%\BakerEngineering\DualSenseXBridge\`.
2. Runs `install-task.ps1` as a deferred CustomAction, which registers
   a scheduled task named `DualSenseXBridge` that:
   - Triggers at user logon
   - Runs `powershell.exe -File <install>\bridge.ps1` hidden, no console
   - Runs as the interactive user (no admin elevation)
   - Restarts on failure up to 999 times with 1-minute interval
3. ViGEmBus and HidHide get installed first by winget because they're
   declared as `Dependencies.PackageDependencies` in the manifest.

## What the MSI does on uninstall

1. Stops and unregisters the `DualSenseXBridge` scheduled task.
2. Kills any running `bridge.ps1` PowerShell process.
3. Removes installed files.

## Design notes (`src/bridge.ps1`)

The bridge is a single PowerShell file. Three design points worth
flagging:

1. **DLL search path**: `SetDllDirectory($PSScriptRoot)` is called before
   any P/Invoke, so the `[DllImport("vigemclient.dll")]` declarations
   resolve to the copy of `vigemclient.dll` shipped next to the script.
   No hardcoded absolute path; works regardless of install location.

2. **DualSense instance-id discovery**: the device-instance-id embeds the
   USB port, so it changes per host and per replug. Rather than baking
   one in, the script queries
   `Get-PnpDevice -PresentOnly -Class HIDClass` filtered by VID/PID on
   every connect attempt.

3. **Log location**: prefers `%ProgramData%\dualsense-xbridge\bridge.log`
   (created on first run); falls back to the script directory if
   `%ProgramData%` isn't writable.

Other characteristics: 1 kHz push rate, 500 ms reconnect backoff,
forever-loop on transient failures, full XInput button mapping including
DPad nibble decode.

## How this is tested

Every push to `main` and every `v*.*.*` tag triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
runs the following parallel jobs on `windows-latest` runners. A green
build means every job in the table passed for the commit:

| Job | What it does | What a pass means |
|---|---|---|
| **`build vigemclient.dll (x64)`** | Checks out [`nefarius/ViGEmClient`](https://github.com/nefarius/ViGEmClient) at the pinned `VIGEMCLIENT_REF`, builds the shared library with `cmake -G "Visual Studio 17 2022" -A x64 -DViGEmClient_DLL=ON -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON`, then runs `dumpbin /EXPORTS` and asserts every `vigem_*` symbol the bridge `DllImport`s is exported. | The x64 native client DLL bundled into our MSI is a fresh, reproducible build from a known upstream commit, not a vendored blob, and contains all required entry points. |
| **`build vigemclient.dll (arm64)`** | Same recipe with `-A ARM64`. | Same guarantee for the arm64 MSI. |
| **`build msi (x64)` / `build msi (arm64)`** | Downloads the matching source-built DLL, runs `candle` + `light` against [`installer/Product.wxs`](installer/Product.wxs), bundles MSI + docs + winget manifests into `DualSenseXBridge-<version>-<arch>.zip`. | WiX accepts every component (UpgradeCode, ProductCode, Win64 attribute, scheduled-task CustomActions) and the MSI is well-formed. |
| **`e2e (xinput state assertions)`** | Installs ViGEmBus on the runner via the official Nefarius installer, then for each fixture in [`tests/fixtures/`](tests/fixtures/) runs the bridge in `-StubReportFile` mode, scans XInput slots 0-3 for the one whose `wButtons` / `sThumbLX` / triggers match expected, asserts. 9 cases cover face buttons (A/B/X/Y), START, dpad, left-stick saturation, and trigger. | The bridge's HID-byte → XInput-state translation is byte-for-byte correct on the actual ViGEm/XInput round trip, not just in code-review. |
| **`perf (sustained rate >= 500 Hz)`** | Runs the bridge with `-MaxReports 5000` against `neutral.bin`, parses the `PERF` log line, asserts sustained processing rate ≥ 500 Hz. On a clean lab box the floor is ~6 kHz. | The PowerShell + P/Invoke per-iter overhead is comfortably below the 1 kHz upstream target — real-time pushing has headroom. Catches major regressions (e.g. an inefficient hot-path refactor). |
| **`publish github release`** | Only fires on `v*.*.*` tag push and only if every job above passed. Downloads both arch bundle zips and creates a GitHub Release with them attached. | The release tag carries matching x64+arm64 artifacts and the bridge passed every check. |

### Running the same checks locally

- **Build the MSI:** `winget install WiXToolset.WiXToolset` once, then `cd installer && powershell -ExecutionPolicy Bypass -File .\build.ps1`. Add `-Arch arm64` for the ARM64 variant (requires an ARM64 vigemclient.dll under `src/`).
- **E2E suite:** `powershell -ExecutionPolicy Bypass -File tests\e2e.ps1`. State-matching means it tolerates one already-running bridge on slot 0; the test bridge will land on slot 1.
- **Perf rate:** `powershell -ExecutionPolicy Bypass -File tests\perf.ps1`. Stop any locally-installed bridge first or the perf bridge will compete with it for ViGEm slots.

## What's NOT done

- Code-signing the MSI (needs a cert; ~$200/yr from DigiCert et al).
- Public winget-pkgs PR (needs a real URL + signed MSI).
- HidHide blocklist auto-config — currently the user must add the
  DualSense (VID_054C&PID_0CE6) to HidHide's blocklist manually after
  install. A post-install CustomAction could do this via `HidHideCLI`,
  but the CLI requires admin and a re-launch — left for v1.1.
- Steam Input PS-controller-disable auto-config — also currently manual
  (`SteamController_PSSupport=0` in `localconfig.vdf`). Out of scope for
  the bridge MSI; belongs in a separate setup helper.
