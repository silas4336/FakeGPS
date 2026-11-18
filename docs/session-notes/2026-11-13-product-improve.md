# 2026-11-13 product-improve（crossplatform/）

分支 `claude/product-improve-197b32`，只動 `crossplatform/`、`lint.yml`、本筆記。未 push。
沒有真實 iPhone：所有裝置端行為都是用 `crossplatform/devtools/` 的假 pymobiledevice3 驗證，標「需實機」的項目**未驗證**。

最終驗證：`cd crossplatform && py -W ignore -m unittest` → `Ran 21 tests ... OK`
（不加 `-W ignore` 也是 OK，只是多印 ResourceWarning：測試裡 kill 掉的子程序 pipe 沒關，不影響結果。）

## 無裝置跑 UI 的方法

```
cd crossplatform
py devtools/fake_server.py 18773          # 不開瀏覽器、狀態寫到暫存目錄，不碰 ~/.fakegps
FAKE_TUNNEL=fail|hang|slow  FAKE_DEVICES=2  FAKE_LOG=路徑    # 環境變數控制假 CLI 行為
```
整個 `devtools/` 可直接刪除，app.py 不依賴它。

## 改動前現況（已驗證）
在 18765 起 `app.H`：`/api/status` → `{"os":"Windows","device_connected":false,...}`，`/` 回 11124 bytes。

---

## E4 最小測試 — `b2854be`
- **改了什麼**：抽出 `pmd3()`、`_tunnel_cmds()`（tunnel/mount/set/play 指令都從這組）；新增 `test_app.py`；新增 `devtools/`；`lint.yml` 新增 `unittest` job。
- **為什麼**：任務要測 `_tunnel_cmds`，但 HEAD 沒有這個函式（任務給的行號也對不上 HEAD，推測是對照原工作區未 commit 版本），所以抽出來。CI 用獨立 job 而不是塞進 shellcheck job，因為兩者無關。
- **驗證**：6 tests OK；假伺服器 `/api/start` → `{"ok":true,"rsd":"fd00::1 51234"}`、`/api/set` → `{"ok":true}`。

## E2 tunnel 期限與錯誤 — `98a5d58`
- **前**：`readline()` 在子程序無輸出時永遠阻塞，30 秒期限不生效；失敗只回固定字串；mount 結果被忽略。
- **後**：`wait_for_rsd()` 讀取執行緒 + `queue.get(timeout)`，逾時 kill；回傳 `step`（detect/tunnel/mount）、可行動提示（`hint_for()` 關鍵字對照：開發者模式、系統管理員、信任、TUN、找不到模組）與完整輸出 `detail`。mount 失敗會報錯。前端顯示 ①偵測 ②tunnel ③掛載 三步（目前步驟閃爍、失敗標紅）＋可展開完整輸出。
- **驗證**：`test_deadline_applies_even_when_child_is_silent`（1 秒期限 <3 秒返回）、`test_hang_times_out`、`test_failure_reports_step_hint_and_full_output` 等 OK。
- **截圖**：`docs/session-notes/img/e2-step-tunnel.png`（進行中）、`e2-connected.png`（成功）、`e2-error.png`（開發者模式錯誤＋完整輸出）。
- **需實機**：真實 pymobiledevice3 的錯誤字樣是否命中 `_HINTS` 的關鍵字（關鍵字是推測的）。

## E1 移動模擬 — `2b12462`
- **前**：沒設起點時起點＝終點（路線 0 m）；路線不畫；無進度、無停止；GPX 最後一點停在離終點不到一步處（終點從未送出）；設定位置 1 秒後程序還活著就說「已設定」。
- **後**：起點預設為最近一次送出的位置（`_last`；中途停止則是當下走到的點）；都沒有就回「沒有起點」。`/api/route` 回 `path`/`distance_m`/`duration_s`/`truncated`；前端畫橘線、移動點、進度條與「已走 / 預估」；新增 `/api/stop` 與「■ 停止」。GPX 一定含終點；超過 5000 點上限明講被截斷。設定成功改說「已送出位置（請在手機地圖確認）」，回傳 `confirmed:false`；失敗附 stderr。
- **UI 驗證時抓到的 bug**：中途停止後 `_last` 仍記成終點，下一段路線起點錯（`e1-drive-progress.jpg` 就是修正前的畫面，線從上一段終點拉過來）。已修並加斷言。
- **截圖**：`e1-set-sent.jpg`、`e1-walk-truncated.jpg`（7 km 步行觸發截斷警告）、`e1-drive-progress.jpg`。
- **行為變更（請確認）**：`set` 子程序 1 秒內**以 0 結束**原本算失敗，現在算成功（rc=0 代表指令成功）。
- **需實機**：`simulate-location play` 停止後手機停在哪；`set` 程序在真機上是常駐還是立即結束。前端進度是用時間推算，不是手機回報。

## E3 輪詢變輕 — `755addc`
- **前**：每次 `/api/status`（前端每 4 秒；連線中每 0.7 秒）都開一個 `usbmux list` 子程序。
- **後**：`device()` 快取偵測結果；tunnel 活著就不偵測；否則最多每 15 秒（`DEVICE_TTL`）重偵測；按連線一律重新偵測。
- **驗證**：假伺服器連打 6 次 `/api/status`，`FAKE_LOG` 中 `usbmux` 只出現 1 次；unittest `test_status_reuses_cached_device`、`test_cache_expires_and_connect_forces_fresh` OK。
- 推測：commit 訊息裡「Windows 上每次約一秒以上」沒有量測，是推測。

## E5 多裝置＋搖桿＋安全插入 — `7fea9cf`
- **多裝置**：`detect_devices()` 回全部；`/api/select`；status 回 `devices`/`device_udid`；裝置 ≥2 台才出現下拉，連線中鎖定。驗證：選 Fake iPhone 2 → 連線 → `FAKE_LOG` 的 start-tunnel 用 `0000FAKE-2`；`MultiDeviceTest` OK。截圖 `e5-device-select.jpg`。
- **搖桿/方向鍵**：右下角 ▲◀◎▶▼＋步距（預設 4 m，同 Swift 版）；焦點在輸入框時方向鍵不攔。與 Swift 版相同：模擬中才送到手機；另外路線播放中不送（避免打斷路線）。節流：同時最多一個 `/api/set` 在途、期間只保留最新。驗證：連按 10 次 ↑ → `FAKE_LOG` 只多 2 次 set，緯度差 0.000036°≈4 m。`nudge:true` 不寫入「最近使用」（`test_nudge_set_skips_recents`）。截圖 `e5-nudge-pad.jpg`（此張為了截圖用 JS 暫時把搖桿移到畫面中，瀏覽器面板截圖只抓到左上區域；實際位置經 `getBoundingClientRect` 確認在右下 850,560–1010,740 @1024×768）。
- **安全插入**：搜尋結果與書籤/最近使用改 `textContent`。驗證：書籤名 `<img src=x onerror=...>` 顯示為純文字、`#bm img` 數量 0、`document.title` 未被改；用 JS 假造 `/api/search` 回應同樣為純文字。截圖 `e5-bookmark-as-text.jpg`。
- 與 Swift 版差異：經度步距除以 cos(緯度)，東西向實際距離才是設定值。

---

## 待問
1. `MAX_GPX_POINTS = 5000`（每秒一點 ≈ 83 分鐘）是刻意的嗎？現在只是明講截斷；要改成取消上限或加大間隔？
2. `set` 程序 1 秒內 rc=0 結束改判成功，是否符合預期？
3. 公開 OSRM 這次兩次都退回直線（未查原因，可能是網路或服務限制）。

## 需實機才能驗證（全部未驗證）
tunnel 真實錯誤訊息對應的提示、DDI 掛載、`set`/`play`/`clear` 在手機上的效果、停止後手機位置、多台實體 iPhone 的 usbmux 輸出格式、搖桿在手機上是否順暢。
