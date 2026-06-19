# FakeGPS — Cross-platform (Windows / Linux / macOS)

A browser-based version of FakeGPS that runs anywhere Python does. The macOS-native SwiftUI app
([../README.md](../README.md)) is the flagship; this version brings the same core to **Windows** and
Linux using a small Python backend (pymobiledevice3) and a Leaflet map UI.

> 跨平台網頁版：Python 後端 + Leaflet 前端，可在 Windows / Linux / macOS 執行。核心與 macOS 原生版相同。

## Windows quick start

1. **Install Python 3.11+** from [python.org](https://www.python.org/downloads/) (tick *Add to PATH*).
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
- Search uses **Photon + OpenStreetMap** (no API key). Movement routing uses the public **OSRM**
  server with a straight-line fallback.
- iOS **17+** only (modern RemoteXPC tunnel). Uses a TCP tunnel (`-p tcp`) which avoids needing a
  TUN driver on Python 3.13+.
- This cross-platform build hasn't been hardware-tested on Windows by the author — please open an
  issue if the tunnel step fails on your setup.

## Files

| File | Purpose |
|------|---------|
| `app.py` | HTTP backend wrapping pymobiledevice3 (OS-aware) |
| `index.html` | Leaflet map UI |
| `run.bat` / `run.sh` | Elevated launchers |
| `requirements.txt` | Python deps |
