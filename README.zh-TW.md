# FakeGPS

[English](README.md) · **繁體中文**

> 用 Mac 模擬 iPhone 的 GPS 位置 —— 搜尋地名、點地圖，位置就跳過去。

一個原生 macOS App（SwiftUI + MapKit），透過 USB 把 iPhone 的 GPS 設成任意位置，
底層使用 [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)。具備 Apple Maps 搜尋、
點地圖設定、常用書籤、Liquid Glass 介面，以及一次性設定後**不用每次輸密碼**的體驗。

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![arch](https://img.shields.io/badge/arch-Universal%20(arm64%20%2B%20x86__64)-success)
![license](https://img.shields.io/badge/license-MIT-green)

![screenshot](docs/screenshot.png)

---

## 快速開始

**方式 A —— 下載即用**（不需 Xcode）

到 [Releases](https://github.com/silas4336/FakeGPS/releases) 下載最新的 `FakeGPS-*.zip`，
解壓後在終端機：

```bash
cd ~/Downloads/FakeGPS
./install.sh
```

**方式 B —— 從原始碼**

```bash
git clone https://github.com/silas4336/FakeGPS.git
cd FakeGPS
./install.sh          # 或 make install
```

兩種方式 `install.sh` 都會自動搞定：安裝相依、設定權限、把 App 裝到 `/Applications`。
插上 iPhone、打開 FakeGPS 就能用。

## 功能

- **原生 SwiftUI App** + Liquid Glass 介面（macOS 26+；舊系統自動降級為毛玻璃材質）
- **Apple Maps 搜尋**（`MKLocalSearch`）—— 免 API key，中／日／英品質都好；結果同時標在地圖上
- **點地圖**設位置（自動反查地名）、拖曳圖釘，或直接輸入座標
- **移動／路線模擬** —— 用 `MKDirections` 算真實道路路線，以步行／騎車／開車速度移動，測導航、運動 app
- **地圖樣式** —— 標準／混合／衛星切換
- **書籤與最近紀錄** —— 常用地點一鍵切換；最近設過的位置自動記住
- **微調搖桿 + 快捷鍵** —— 方向鍵微移位置（適合遊戲/AR）、⌘⏎ 設定、⌘K 清除
- **不用反覆輸密碼** —— 安裝時設好的 NOPASSWD helper
- 支援 **iOS 17+**（現代 RemoteXPC tunnel）、**Apple Silicon 與 Intel**（Universal binary）

## 系統需求

| 需求 | 說明 |
|------|------|
| macOS 14+ | Apple Silicon 或 Intel 皆可 |
| Xcode Command Line Tools | `xcode-select --install`（**不需**完整 Xcode；僅從原始碼編譯時需要）|
| Homebrew | 安裝程式會在缺少時主動幫你裝 |
| iPhone 開發者模式 | 設定 → 隱私權與安全性 → 開發者模式 |

`libimobiledevice` 與 `pymobiledevice3` 由安裝程式自動處理。

## 使用方式

1. iPhone 用 USB 接上 Mac、解鎖、點 **信任**。
2. 開啟 **FakeGPS**（首次被 Gatekeeper 擋的話：對 App 按右鍵 → 打開 → 打開）。
3. 按 **連線手機** 建立 tunnel（免密碼）。
4. 搜地點 / 點地圖 / 用書籤，再按 **設定**。
5. 打開手機地圖確認藍點移動了。

模擬位置是**暫時**的：清除、關閉 App、拔線或手機重開都會還原成真實 GPS，不會永久改動手機。

## Make 指令

```
make install     # 完整安裝（相依 + 編譯 + 權限 + 裝到 /Applications）
make build       # 只編譯 Universal App 到 ./build
make run         # 編譯並開啟
make doctor      # 診斷環境是否就緒
make uninstall   # 解除安裝
```

遇到問題先跑 **`make doctor`** —— 它會逐項檢查並告訴你缺什麼、怎麼補。

## 運作原理

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
tunnel 需要 root，所以安裝時設一支 root-owned helper，並在 `/etc/sudoers.d/fakegps`
只授權「安裝者本人」免密碼執行 —— 這就是執行時不用再輸密碼的原因。

## 疑難排解

| 症狀 | 解法 |
|------|------|
| 雙擊跳「無法驗證開發者」 | 對 App 按右鍵 → 打開 → 打開（ad-hoc 簽章、未公證）|
| 狀態一直「未偵測到手機」 | 用可傳資料的線、手機解鎖、點「信任」；跑 `make doctor` |
| 連線手機逾時 | iPhone 要開**開發者模式**；重插 USB 再試 |
| 連線手機要求密碼 | 免密碼權限沒設好 → 重跑 `./install.sh` |
| 設定後地圖沒跳 | 在手機地圖按定位鍵；確認狀態列顯示「模擬中」|

## 免責聲明

僅供**正當用途**：App 開發、測試定位功能、隱私保護。用來欺騙服務、違反服務條款或詐欺，
責任自負。請合法且合乎道德地使用。

## 授權

MIT —— 見 [LICENSE](LICENSE)。
