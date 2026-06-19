# FakeGPS — 專案說明與接手指南（給 Claude Code）

> 這份檔案是給「接手這個 repo 的 Claude」看的。它**沒有先前對話的記憶**，請完全依此檔理解專案、目前狀態與待辦。

## 這是什麼

FakeGPS 透過 USB 把 iPhone 的 GPS 位置模擬成任意座標，底層用 [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)（純 Python，跨平台）。

兩個前端，共用同一套「pymobiledevice3 設位置」邏輯：

| 路徑 | 平台 | 狀態 |
|------|------|------|
| `FakeGPS.swift`（根目錄）+ `build.sh`/`install.sh` | **macOS 原生**（SwiftUI + MapKit） | ✅ 完成可用，已在 macOS 實機測過 |
| `crossplatform/`（`app.py` + `index.html`） | **Windows / Linux / macOS 網頁版** | ⚠️ 後端在 macOS 驗證過、Windows `.exe` 在 CI 編得起來，但**尚未在 Windows + iPhone 實機測試** |

## 🎯 在這台 Windows 上的任務

把 `crossplatform/` 版本在**真實 Windows + iPhone** 上跑起來、測試、修正。重點是 **tunnel 建立**那段（最可能卡）。測出問題就修 `crossplatform/app.py`、把 Windows 特有的設定/踩雷補進 `crossplatform/README.md`，並 commit。

## 如何在 Windows 執行與測試

**前提（缺一不可）**
1. 安裝 **Python 3.11+**（python.org，勾選 Add to PATH）
2. 安裝 **Apple 裝置 app**（Microsoft Store）或 iTunes — 提供 Windows 與 iPhone 的 USB 溝通（usbmux）
3. iPhone 開 **開發者模式**（設定 → 隱私權與安全性 → 開發者模式），USB 接上、解鎖、點「信任」

**執行**
```cmd
:: 以系統管理員身分（tunnel 需要）；run.bat 會自動跳 UAC 提權
crossplatform\run.bat
```
或在「系統管理員」終端機：`python -m pip install -U pymobiledevice3 && python crossplatform\app.py`
（會開瀏覽器到 http://127.0.0.1:8765）

**手動偵錯指令**（在系統管理員終端機）
```cmd
:: 1. 看裝置有沒有被抓到（不需 admin）
python -m pymobiledevice3 usbmux list

:: 2. 手動建 tunnel 看真正的錯誤（需 admin）——最容易卡的一步
python -m pymobiledevice3 remote start-tunnel -t usb --udid <UDID> -p tcp --script-mode
::   成功會印出一行 "HOST PORT"（例如 fd00::1 51234）並持續掛著

:: 3. 用上面的 HOST PORT 掛 DDI 並設位置
python -m pymobiledevice3 mounter auto-mount --rsd <HOST> <PORT>
python -m pymobiledevice3 developer dvt simulate-location set --rsd <HOST> <PORT> -- 25.0338 121.5645
```

## ⚠️ 關鍵踩雷（務必先讀，這些都是踩過的坑）

1. **`simulate-location set` 的 `--rsd` 必須放在 `--` 之前**，否則 `--` 之後的東西被當成位置參數，pymobiledevice3 會報 `Got unexpected extra argument (--rsd ...)` → 設定失敗。正確：`set --rsd HOST PORT -- LAT LON`。（`app.py` 已是正確順序，改動時別弄反。）
2. **tunnel 需要系統管理員權限**（建立網路介面）。Windows 沒有 sudo，靠 UAC；`run.bat` 已會自動提權。
3. **iOS 17+** 才有的 RemoteXPC tunnel。用 `-p tcp`（Python 3.13+）可避免需要 TUN 驅動；若 Windows 上 tcp tunnel 失敗，試 `-p quic` 或查 pymobiledevice3 的 Windows tunnel 需求（可能要 WinTUN / Wintun.dll）。
4. **pymobiledevice3 要新版（>=4）**。舊版（如 2.x）搭新版 `qh3`（>=1.0）建 QUIC tunnel 會 crash（`KeyError: Epoch.ONE_RTT`）。`pip install -U pymobiledevice3` 即可。
5. 裝置偵測用 `pymobiledevice3 usbmux list`（跨平台），**不需要** libimobiledevice（那是 macOS CLI 用的）。
6. 搜尋走 **Photon + OpenStreetMap**（免金鑰）；路線走公開 **OSRM**，失敗則直線。都用 `curl`（Windows 10+ 內建 curl.exe）或 urllib。

## 檔案地圖（crossplatform/）

| 檔案 | 用途 |
|------|------|
| `app.py` | 本機 HTTP 後端，包 pymobiledevice3。端點：`/api/status`、`/api/start`(建 tunnel)、`/api/set`、`/api/clear`、`/api/route`、`/api/search`、`/api/bookmarks*` |
| `index.html` | Leaflet 地圖 UI |
| `run.bat` / `run.sh` | 提權啟動器 |
| `requirements.txt` | `pymobiledevice3` |

`.github/workflows/build-windows.yml` 會在 GitHub Windows runner 用 PyInstaller 打包單一 `.exe`（手動觸發或打 `v*` tag）。

## Commit 慣例

Conventional commits（`feat:`/`fix:`/`docs:`…），commit 訊息結尾加：
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

## 僅限 macOS、Windows 不適用的部分（別套用到 Windows）

- 根目錄的 `FakeGPS.swift`、`build.sh`、`install.sh`（用 swiftc + NOPASSWD sudoers helper）都是 macOS 專屬。
- Windows 上**不要**碰那些；只動 `crossplatform/`。
