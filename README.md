# DualSense XBridge

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
   `manifests/b/BakerEngineering/DualSenseXBridge/1.0.0/`, open a PR.

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
