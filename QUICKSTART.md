# Quick Start — DualSense XBridge for Warzone

End-to-end setup on a fresh Windows 10/11 box, from zero to "Warzone sees
an Xbox 360 controller while you play KBM through the BBB". Estimated time:
**~10 minutes** once the BBB is reachable and your network is up.

If anything goes sideways, jump to [Troubleshooting](#troubleshooting) at
the bottom.

---

## 0. Prerequisites

| Item | Version | Notes |
|---|---|---|
| Windows | 10 (1809+) or 11 | x64 only |
| PowerShell | 5.1+ | ships in-box |
| BBB | reachable + flashed | running the DualSense FunctionFS daemon |
| USB cable | data, not charge-only | BBB plugged into the host |

Before starting, confirm the BBB is presenting itself as a DualSense by
running this in any PowerShell window (no admin needed):

```powershell
Get-PnpDevice -PresentOnly -InstanceId 'USB\VID_054C&PID_0CE6\*'
```

You should see one entry, `Status=OK`. If it says `Error` /
`CM_PROB_FAILED_START` — fix the BBB side first; the bridge can't recover
from that on the Windows side.

---

## 1. Install the three components (one command)

Open an **elevated** PowerShell (Run as Administrator). Then:

```powershell
winget install BakerEngineering.DualSenseXBridge
```

Because the bridge's winget manifest declares ViGEmBus and HidHide as
dependencies, winget pulls all three in the right order:

1. **`Nefarius.ViGEmBus`** — kernel-mode bus driver. Exposes virtual
   Xbox 360 / DS4 controllers to Windows. Reboots may be prompted; allow it.
2. **`Nefarius.HidHide`** — filter driver. Hides USB HID devices from
   selected processes so games don't see two controllers at once.
3. **`BakerEngineering.DualSenseXBridge`** — this project. Installs `bridge.ps1` +
   `vigemclient.dll` to `%ProgramFiles%\BakerEngineering\DualSenseXBridge\` and
   registers a scheduled task that runs the bridge on every user logon.

If you prefer manual:

```powershell
winget install Nefarius.ViGEmBus
winget install Nefarius.HidHide
winget install BakerEngineering.DualSenseXBridge
```

After install completes (and a reboot if ViGEmBus asked for one), sign
back in. The scheduled task launches the bridge automatically; you don't
have to start anything by hand.

---

## 2. Configure HidHide (one-time, manual until v3.1)

HidHide ships with an empty blocklist. Until the bridge's post-install
helper lands in v3.1, add the BBB DualSense by hand:

1. From the Start menu, open **HidHide Configuration Client** (admin
   prompt; allow).
2. **Devices** tab:
   - Find the entry whose Device Instance Path starts with
     `HID\VID_054C&PID_0CE6\…` (the BBB DualSense).
   - Check the box next to it. (Tick *Show all devices* if it's hidden.)
3. **Enable device hiding** — toggle ON (top-right of the window).
4. **Applications** tab:
   - Click **Add** and browse to
     `C:\Program Files\BakerEngineering\DualSenseXBridge\bridge.ps1`.
     This whitelists the bridge so it can still see the DualSense even
     though everyone else is blocked.

That's it. Close HidHide. The DualSense is now invisible to every
process except the bridge.

**Verify:** open Game Controllers (`joy.cpl`). You should see exactly
one controller listed — *Controller (Xbox 360 For Windows)*. If you see
two, HidHide isn't fully wired up yet.

---

## 3. Disable Steam Input for PS controllers (skip if Steam isn't installed)

Steam, by default, grabs anything that looks like a DualShock 4 or
DualSense and tries to wrap its own input layer around it. That fights
the bridge. Turn it off:

1. In Steam: **Steam → Settings → Controller**.
2. Disable **PlayStation Controller Support**.
3. If you launch Warzone through Steam:
   - Right-click your **Battle.net** shortcut → **Properties** →
     **Controller** → set to **Disable Steam Input**.
   - In the same Properties dialog, edit **Target** to point at
     `Battle.net.exe` directly (not `Battle.net Launcher.exe`).
     Steam Input has known quirks with the launcher EXE.

If you don't use Steam at all, skip this section.

---

## 4. Smoke test

With everything installed:

1. Hit a few buttons / move the sticks on whatever's driving the BBB
   (your KBM, your test harness, whatever).
2. Open Game Controllers (`joy.cpl`) → select the X360 controller →
   **Properties**. You should see buttons light up and sticks move in
   real time.
3. Check the bridge log:
   ```powershell
   Get-Content "$env:ProgramData\dualsense-xbridge\bridge.log" -Tail 5
   ```
   You should see a `START vigem-idx=…` line at the top of the recent
   tail and a steady stream of `tick count=…` lines every 30 seconds.

If both look right, **launch Warzone** — it should see one Xbox 360
controller, apply aim-assist + controller deadzones, and let you play.

---

## 5. Day-to-day operation

- The bridge auto-starts at every logon (scheduled task
  `DualSenseXBridge`). You never need to start it manually.
- If the BBB-side daemon restarts, the bridge reconnects within ~500 ms.
- If you replug the BBB cable, the bridge picks the new device-instance-id
  automatically.

Useful commands:

```powershell
# Check whether the bridge is running
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*bridge.ps1*' } |
  Select-Object ProcessId, CreationDate

# Manually restart the scheduled task (e.g. after BBB changes)
Stop-ScheduledTask -TaskName DualSenseXBridge
Start-ScheduledTask -TaskName DualSenseXBridge

# Live-tail the bridge log
Get-Content "$env:ProgramData\dualsense-xbridge\bridge.log" -Wait -Tail 0
```

---

## 6. Uninstall

```powershell
winget uninstall BakerEngineering.DualSenseXBridge
```

That removes the bridge, the scheduled task, and kills any running
bridge processes. ViGEmBus and HidHide stay installed — they're useful
for other tools (DS4Windows, reWASD, etc.). To remove them too:

```powershell
winget uninstall Nefarius.HidHide
winget uninstall Nefarius.ViGEmBus
```

---

## Troubleshooting

### Bridge log shows `cannot open DualSense, err=2` repeatedly

The bridge can't find the DualSense gadget on the wire. Either:
- The BBB isn't currently in DualSense-emulation mode (it might be in
  passthrough — switch back), or
- USB cable is charge-only, or
- The BBB-side daemon has crashed (`systemctl status dualsense-ffsd` on
  the BBB).

### Bridge log shows `vigem_connect rc=0xE0000204`

ViGEmBus driver isn't installed or isn't running. Re-run
`winget install Nefarius.ViGEmBus` and reboot.

### Warzone sees two controllers / picks the wrong one

HidHide isn't blocking the physical DualSense. Re-open HidHide
Configuration Client, confirm the DualSense is checked under **Devices**
and the master toggle (**Enable device hiding**) is ON. Confirm
`bridge.ps1` is in the **Applications** whitelist.

### `Status=Error / CM_PROB_FAILED_START` on the DualSense

The BBB-side gadget is in a broken state. Recovery options, in order
of escalation:
1. **Restart the BBB daemon** (BBB-side):
   `systemctl restart dualsense-ffsd`
   On a healthy kernel + writer-thread fix, this is invisible to the
   Windows host (~2 s blip).
2. **Physical unplug + replug** the BBB. May or may not recover
   depending on which kernel the BBB is running.
3. **Reboot the BBB.** Always works.

Note: `pnputil /restart-device` on the Windows side reports "Device
restarted successfully" but does **not** actually clear
`CM_PROB_FAILED_START`. Don't waste time on it.

### Scheduled task didn't get created

Re-run the bridge MSI uninstall + install (the schtask is created via
a CustomAction during install). Or create it manually:

```powershell
schtasks /Create /TN DualSenseXBridge `
  /XML "C:\Program Files\BakerEngineering\DualSenseXBridge\bridge-task.xml" /F
```

### Bridge is using high CPU

It's supposed to run at ~1000 reports/sec, which on a modern CPU is
around 1–3 % of one core. If you see double-digit %, something else is
contending — possibly DS4Windows is also running. Make sure it isn't:

```powershell
Get-Process -Name DS4Windows -ErrorAction SilentlyContinue
```

If anything comes back, kill it and stop it from auto-starting.

### "Where do logs go?"

`%ProgramData%\dualsense-xbridge\bridge.log`
(usually `C:\ProgramData\dualsense-xbridge\bridge.log`).

If that path isn't writable (rare), the bridge falls back to writing
`bridge.log` next to `bridge.ps1` in the install folder.
