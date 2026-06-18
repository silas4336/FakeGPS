# FakeGPS

> Simulate your iPhone's GPS location from your Mac — search any place, tap the map, done.

A native macOS app (SwiftUI + MapKit) that spoofs an iPhone's location over USB via
[pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Apple Maps search, tap-to-set
map, bookmarks, Liquid Glass UI, and a one-time setup that means **no password prompt every time**.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![arch](https://img.shields.io/badge/arch-Universal%20(arm64%20%2B%20x86__64)-success)
![license](https://img.shields.io/badge/license-MIT-green)

![screenshot](docs/screenshot.png)

> 用 Mac 模擬 iPhone 的 GPS 位置。搜地名、點地圖，手機位置就跳過去。原生 SwiftUI + MapKit、Liquid Glass 介面。

---

## 🚀 Quick Start

```bash
git clone https://github.com/silas4336/FakeGPS.git
cd FakeGPS
./install.sh        # 或 make install
```

`install.sh` 會自動補齊所有相依、編譯、設定權限、把 App 裝到 `/Applications`。
裝完插上 iPhone、開 FakeGPS 就能用。就這樣。

> 之後 repo 公開後可一行安裝：
> `curl -fsSL https://raw.githubusercontent.com/silas4336/FakeGPS/main/bootstrap.sh | bash`

## ✨ Features

- **原生 SwiftUI App** + Liquid Glass 介面（macOS 26+；舊版自動降級為毛玻璃）
- **Apple Maps 搜尋**（`MKLocalSearch`）— 免 API key，中／日／英地標品質都好
- **點地圖設位置**、拖曳圖釘，或直接打座標
- **常用地點書籤**，一鍵切換
- **零互動 tunnel** — 不用每次輸密碼（安裝時設好的 NOPASSWD helper）
- 支援 **iOS 17+**（現代 RemoteXPC tunnel）、**Intel 與 Apple Silicon**（Universal binary）

## ✅ Requirements

| 需求 | 說明 |
|------|------|
| macOS 14+ | Apple Silicon 或 Intel 皆可 |
| Xcode Command Line Tools | `xcode-select --install`（**不需**完整 Xcode）|
| Homebrew | 安裝程式會在缺少時主動幫你裝 |
| iPhone 開發者模式 | 設定 → 隱私權與安全性 → 開發者模式 |

`libimobiledevice` 與 `pymobiledevice3` 由安裝程式自動處理。

## 🕹️ Usage

1. iPhone 用 USB 接上 Mac、解鎖、點 **信任**
2. 開啟 **FakeGPS**（首次被 Gatekeeper 擋的話：右鍵 → 打開 → 打開）
3. 按 **連線手機**（建立 tunnel，免密碼）
4. 搜地點 / 點地圖 / 用書籤 → **設定到這裡**
5. 打開手機地圖確認藍點移動了

模擬位置是**暫時**的：清除、關閉 App、拔線或手機重開都會還原成真實 GPS，不會永久改動手機。

## 🛠️ Make 指令

```
make install     # 完整安裝
make build       # 只編譯到 ./build
make run         # 編譯並開啟
make doctor      # 診斷環境是否就緒
make uninstall   # 解除安裝
```

環境有問題時先跑 **`make doctor`**（或 `./doctor.sh`），它會逐項告訴你缺什麼、怎麼補。

## 🧩 How it works

```
┌─────────────────┐   Process    ┌──────────────────────┐  USB tunnel  ┌────────┐
│  FakeGPS.app    │ ───────────▶ │  pymobiledevice3     │ ───────────▶ │ iPhone │
│  (SwiftUI UI)   │              │  (Python)            │              └────────┘
└─────────────────┘              └──────────────────────┘
        │ sudo -n (NOPASSWD)
        ▼
  /usr/local/libexec/fakegps_tunnel.sh   ← root-owned helper，建立 RemoteXPC tunnel
```

Swift App 是輕量原生外殼，透過 `Process` 驅動 `pymobiledevice3` 掛載 DDI、設定/清除位置。
tunnel 需要 root，所以安裝時設一支 root-owned helper 並在 `/etc/sudoers.d/fakegps` 只授權
「安裝者本人」免密碼執行 —— 這就是執行時不用再輸密碼的原因。

## 🩹 Troubleshooting

| 症狀 | 解法 |
|------|------|
| App 雙擊跳「無法驗證開發者」 | 右鍵 → 打開 → 打開（App 是 ad-hoc 簽章、未公證）|
| 狀態一直顯示「未偵測到手機」 | 確認線材可傳資料、手機已解鎖、已點「信任」；跑 `make doctor` |
| 連線手機逾時 | iPhone 要開**開發者模式**；重插 USB 再試 |
| 連線手機要求密碼 | 免密碼權限沒設好 → 重跑 `./install.sh` |
| 設定位置後地圖沒跳 | 在手機地圖按定位鍵；確認狀態列顯示「模擬中」 |

## ⚠️ Disclaimer

僅供**正當用途**：App 開發、測試定位功能、隱私保護。用來欺騙服務、違反服務條款或詐欺，
責任自負。請合法且合乎道德地使用。

## 📄 License

MIT — see [LICENSE](LICENSE).
