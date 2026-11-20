# Architecture / 程式碼地圖（2026-11-21）

FakeGPS sets an iPhone's GPS location over USB with [pymobiledevice3](https://github.com/doronz88/pymobiledevice3).
There are two front ends that share the same device logic:

| Path | Platform | Shape |
|---|---|---|
| `FakeGPS.swift` + `build.sh` / `install.sh` | macOS native (SwiftUI + MapKit) | Single Swift file; calls pymobiledevice3 through a NOPASSWD sudo helper |
| `crossplatform/` | Windows / Linux / macOS | Python HTTP backend (`app.py`) + Leaflet page (`index.html`) |

The rest of this page covers `crossplatform/`.

## 1. `crossplatform/app.py` layers

| Layer | Functions | Notes |
|---|---|---|
| Subprocess | `PMD3`, `pmd3()`, `run()` | Script mode runs `python -m pymobiledevice3`; a PyInstaller `.exe` re-invokes itself with the `__pmd3__` sentinel |
| Device detection | `detect_devices()`, `device()`, `select_device()` | `usbmux list`, cached for `DEVICE_TTL` (15 s) so status polling doesn't spawn a process every time |
| Tunnel | `start_tunnel()` → `_start_tunnel()`, `_tunnel_cmds()`, `wait_for_rsd()`, `hint_for()` | `lockdown start-tunnel` first (iOS 17.4+), then `remote start-tunnel -t usb`; waits up to `TUNNEL_TIMEOUT` for the `HOST PORT` line, then auto-mounts the DDI. `_tunnel_lock` lets only one connect run at a time |
| Location | `_device_cmds()`, `set_location()`, `clear_location()`, `_spawn_sim()` | `simulate-location set --rsd HOST PORT -- LAT LON` (`--rsd` must come before `--`). The set process stays alive to hold the location; its stderr goes to a temp file, not a pipe |
| Route | `route_coords()`, `gpx_points()`, `make_gpx()`, `play_route()`, `stop_sim()` | Road route from routing.openstreetmap.de (foot / bike / car) → OSRM demo (car only) → straight line; resampled to one point per second at the mode's speed (max `MAX_GPX_POINTS`); played with `simulate-location play` |
| Search | `_curl_json()`, `geocode()` | Photon + OSM, decoded as UTF-8 |
| Storage | `jload()`, `jsave()` | `~/.fakegps/bookmarks.json`, `recents.json` (last 12), `route.gpx` |
| HTTP | `H`, `coord()`, `main()` | Binds `127.0.0.1:8765`. `_local_only()` rejects any `Host` other than `127.0.0.1` / `localhost` on that port and any foreign `Origin` (403). `coord()` type- and range-checks every coordinate |

Runtime state lives in three module dicts: `_tunnel` (tunnel process, RSD host/port, current step), `_sim` (location/route process and its start time) and `_last` (last position sent, the default route start).

## 2. Data flow

```
browser (index.html, Leaflet)
  │  polls GET /api/status every few seconds
  │  POST /api/start ───────► start_tunnel ─► usbmux list ─► lockdown|remote start-tunnel (kept running)
  │                                                     └─► mounter auto-mount --rsd HOST PORT
  │  POST /api/set ─────────► coord() ─► set_location ─► simulate-location set (kept running) ─► recents.json
  │  POST /api/route ───────► coord() ─► route_coords (HTTP via curl) ─► gpx_points ─► route.gpx
  │                                                                   └► simulate-location play (kept running)
  │  POST /api/stop|clear ──► stop_sim / simulate-location clear
  │  GET  /api/search ──────► geocode (Photon)
  └  GET/POST /api/bookmarks* ► bookmarks.json
```

Every request first goes through `H._local_only()`. The server runs as Administrator/root because the tunnel creates a network interface, so this check is what keeps other web pages from driving the phone.

## 3. Tests and dev tools

- `crossplatform/test_app.py` — stdlib `unittest`, no iPhone needed: `cd crossplatform && py -m unittest`. Covers GPX resampling, tunnel command order and fallbacks, RSD parsing, UTF-8 decoding, routing fallbacks, the start-tunnel chain against a fake pymobiledevice3, movement, status polling, multiple devices, coordinate validation, clear failures, the tunnel lock and the local-only HTTP check.
- `crossplatform/devtools/fake_pmd3/` — a fake `pymobiledevice3` package (behaviour set by environment variables) used by the tests and by `devtools/fake_server.py`, which starts the UI on port 18765 with a temporary state folder.
- `.github/workflows/build-windows.yml` — builds the single Windows `.exe` with PyInstaller (`FakeGPS.spec`).
