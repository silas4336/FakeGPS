# FakeGPS

A native macOS app to simulate your iPhone's GPS location over USB — search any place by name, drop a pin on the map, and your phone jumps there. Built with SwiftUI + MapKit, powered by [pymobiledevice3](https://github.com/doronz88/pymobiledevice3).

> 用 USB 模擬 iPhone 的 GPS 位置。搜尋地名、在地圖上點一下，手機位置就跳過去。原生 SwiftUI + MapKit 介面、Liquid Glass 質感。

![screenshot](docs/screenshot.png)

## Features

- **Native SwiftUI app** with Liquid Glass UI (macOS 26+, graceful fallback on older systems)
- **Apple Maps search** (`MKLocalSearch`) — no API key needed, high-quality POI results in any language
- **Tap-to-set** on a full-screen map, or type coordinates directly
- **Bookmarks** for frequently-used locations
- **Zero-interaction tunnel** — no password prompt every time (via a NOPASSWD helper set up at install)
- Works on **iOS 17+** (uses the modern RemoteXPC tunnel)

## Requirements

- macOS 14+ (Apple Silicon or Intel — the app is a Universal binary)
- Xcode **Command Line Tools** (`xcode-select --install`) — full Xcode is *not* required
- [Homebrew](https://brew.sh)
- An iPhone with **Developer Mode** enabled (Settings → Privacy & Security → Developer Mode)

The installer pulls the rest (`libimobiledevice`, `pymobiledevice3`) automatically.

## Install

```bash
git clone https://github.com/<you>/FakeGPS.git
cd FakeGPS
./install.sh
```

The installer will:
1. Install `libimobiledevice` (Homebrew) and `pymobiledevice3` (pip)
2. Compile a Universal `FakeGPS.app`
3. Set up a NOPASSWD helper so the app can create the USB tunnel without asking for your password every time (asks for your password **once**, during install)
4. Copy the app to `/Applications`

First launch may be blocked by Gatekeeper (the app is ad-hoc signed, not notarized) — **right-click the app → Open → Open**.

## Usage

1. Plug in your iPhone via USB, unlock it, tap **Trust** if prompted
2. Open **FakeGPS** (Launchpad / Applications)
3. Click **連線手機 / Connect** (builds the tunnel — no password needed)
4. Search a place, tap the map, or enter coordinates → **Set**
5. Open Maps on your phone to confirm the blue dot moved

The simulated location is **temporary** — it reverts to real GPS when you clear it, quit the app, unplug, or reboot the phone. Nothing on the phone is permanently changed.

## How it works

```
┌─────────────────┐   Process    ┌──────────────────────┐  USB tunnel  ┌────────┐
│  FakeGPS.app    │ ───────────▶ │  pymobiledevice3     │ ───────────▶ │ iPhone │
│  (SwiftUI UI)   │              │  (Python)            │              └────────┘
└─────────────────┘              └──────────────────────┘
        │ sudo -n (NOPASSWD)
        ▼
  /usr/local/libexec/fakegps_tunnel.sh   ← root-owned helper, creates the RemoteXPC tunnel
```

The Swift app is a thin native shell: it drives `pymobiledevice3` via `Process` to mount the
Developer Disk Image, set the location, and clear it. The tunnel needs root, so a small
root-owned helper is whitelisted in `/etc/sudoers.d/fakegps` for the installing user only —
that's why no password is needed at runtime.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, the helper, and the sudoers rule.

## Disclaimer

This tool is for **legitimate purposes** only — app development, testing location-based features,
and privacy. Spoofing your location to deceive services, violate terms of service, or commit fraud
is your responsibility. Use it ethically and legally.

## License

MIT — see [LICENSE](LICENSE).
