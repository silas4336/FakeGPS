# FakeGPS — Cross-platform (Windows / Linux / macOS)

A browser-based version of FakeGPS that runs anywhere Python does. The macOS-native SwiftUI app
([../README.md](../README.md)) is the flagship; this version brings the same core to **Windows** and
Linux using a small Python backend (pymobiledevice3) and a Leaflet map UI.

> 跨平台網頁版：Python 後端 + Leaflet 前端，可在 Windows / Linux / macOS 執行。核心與 macOS 原生版相同。

## Windows quick start

1. **Install Python 3.11+** from [python.org](https://www.python.org/downloads/) (tick *Add to PATH*).
   ⚠️ Do **not** rely on the *Microsoft Store* Python — its `python.exe` is an empty App-Execution-Alias
   stub that silently does nothing. `run.bat` works around this by preferring the `py` launcher.
2. **Install Apple's USB driver** — the **Apple Devices** app from the Microsoft Store (or iTunes).
   This is what lets Windows talk to your iPhone over USB.
3. **Enable Developer Mode** on the iPhone (Settings → Privacy & Security → Developer Mode).
4. Double-click **`run.bat`**. It will:
   - request Administrator rights (the tunnel needs them),
   - install `pymobiledevice3`,
   - start the server and open the UI in your browser.
5. Plug in the iPhone, unlock, tap **Trust**, then click **Connect** in the UI.

### Prefer a single `.exe`?
A prebuilt Windows executable is produced by GitHub Actions (`build-windows` workflow) — see the
repo's Actions/Releases. Run it **as Administrator**. (Apple Devices app + Developer Mode are still required.)

## macOS / Linux

```bash
cd crossplatform
./run.sh           # uses sudo (tunnel needs root)
```
On macOS you likely want the native app instead — see the main README.

## Notes & limitations

- **Admin/root is required** for the USB tunnel on every OS (Windows UAC / `sudo`). There's no
  password-less helper here (that's a macOS-only convenience in the native app).
- Search uses **Photon + OpenStreetMap** (no API key). Movement routing uses FOSSGIS
  **routing.openstreetmap.de** (separate foot / bike / car networks), then the public **OSRM** demo
  server, then a straight line. (The OSRM demo only has a car profile — asking it for `foot` silently
  returns the driving route.)
- The local API only answers requests whose `Host` is `127.0.0.1` / `localhost` on its own port, and
  whose `Origin` (if any) matches. Other web pages can't move your phone or read device info
  (CSRF / DNS-rebinding protection). Coordinates are type- and range-checked before they reach the device.
- iOS **17+** only (modern RemoteXPC tunnel). The backend tries `lockdown start-tunnel` first and
  falls back to `remote start-tunnel -t usb`. On iOS 17.4+ (incl. iOS 18 / 26+) only the
  `lockdown` path works — the old `remote -t usb` path returns *"No tunnel services discovered /
  Device is not connected"*.
- **Hardware-tested on Windows 11 + iPhone (iOS 27) ✅** — connect, set-location and the full
  tunnel → mount → set chain all verified. If the tunnel step fails on your setup, please open an issue.

### Windows tunnel troubleshooting (tested gotchas)
- **Run as Administrator** — the tunnel creates a network interface and needs it (`run.bat` self-elevates via UAC).
- **`No tunnel services discovered` / `Device is not connected`** → you're on the old `remote -t usb`
  path against iOS 17.4+. Fixed by using `lockdown start-tunnel` (already the default now).
- Quick manual check (in an **Administrator** terminal):
  ```cmd
  py -m pymobiledevice3 usbmux list
  py -m pymobiledevice3 lockdown start-tunnel --udid <UDID> --script-mode
  :: prints "HOST PORT", e.g.  fdfc:a23a:87f3::1 53540  — keep this window open
  py -m pymobiledevice3 mounter auto-mount --rsd <HOST> <PORT>
  py -m pymobiledevice3 developer dvt simulate-location set --rsd <HOST> <PORT> -- 25.0338 121.5645
  ```
  Note: `--rsd HOST PORT` must come **before** `--`, and `simulate-location set` keeps running
  ("Press ENTER to exit") to hold the location.

## Files

| File | Purpose |
|------|---------|
| `app.py` | HTTP backend wrapping pymobiledevice3 (OS-aware) |
| `index.html` | Leaflet map UI |
| `run.bat` / `run.sh` | Elevated launchers |
| `requirements.txt` | Python deps (pinned `pymobiledevice3`) |
| `test_app.py` | Unit tests, stdlib only: `cd crossplatform && py -m unittest` |
| `devtools/` | Fake `pymobiledevice3` + `fake_server.py` to run the UI without an iPhone |

Architecture and data flow: [`../docs/architecture.md`](../docs/architecture.md).
