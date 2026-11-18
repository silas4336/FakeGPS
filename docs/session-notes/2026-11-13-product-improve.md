# 2026-11-13 product-improve（crossplatform/）

分支：`claude/product-improve-197b32`。用量上限中斷，只完成 E4。

## 現況可啟動（已驗證）
改動前用 scratch 腳本在 18765 起 `app.H`：`/api/status` 回 `{"os":"Windows","device_connected":false,...}`，`/` 回 11124 bytes。

## E4 最小測試 ✅（commit b2854be）
- 改了什麼：`app.py` 新增 `pmd3()`、`_tunnel_cmds(udid, host, port, lat, lon, gpx)`，tunnel/mount/set/play 指令都從這裡組；新增 `crossplatform/test_app.py`（6 個 unittest）；`devtools/`（假 pymobiledevice3 CLI + `fake_server.py`，可整個刪）；`lint.yml` 新增 `unittest` job（獨立 job 而非塞進 shellcheck job 的 step，因為兩者無關）。
- 為什麼：任務指定測 `_tunnel_cmds`，但 HEAD 的 app.py 沒有這個函式（任務的行號對不上 HEAD，推測是對照原工作區未 commit 版本），所以抽出來。
- 驗證：`cd crossplatform && py -m unittest -v` → `Ran 6 tests ... OK`。
  `py devtools/fake_server.py 18766` 後：status → `device_connected:true, "Fake iPhone 1"`；`POST /api/start` → `{"ok":true,"rsd":"fd00::1 51234"}`；`POST /api/set` → `{"ok":true}`。
- 發現（未修）：`make_gpx` 最後一點是 `int(total/step)*step`，不含終點；且上限 5000 點 → 步行約 7 km、開車約 69 km 以上會被截斷、停在半路。單點路線輸出 2 個相同點。

## 未做
E2（tunnel 期限＋完整錯誤＋步驟顯示）、E1（起點預設、畫路線、進度、/api/stop、誠實回報）、E3（快取 udid、輕量輪詢）、E5（多裝置、搖桿/鍵盤、搜尋結果改文字節點）。UI 截圖尚未做。

## 待問
- `make_gpx` 5000 點上限是刻意的嗎？要改成加大 step（會變快）還是取消上限？

## 需實機才能驗證
所有 tunnel / mount / set / play 實際行為（未驗證，需實機）。
