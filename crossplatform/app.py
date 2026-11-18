#!/usr/bin/env python3
"""FakeGPS — cross-platform (Windows / Linux / macOS) backend.

本機 HTTP 伺服器 + 瀏覽器前端，包裝 pymobiledevice3 的 iOS 位置模擬功能。
與 macOS 原生 Swift 版共用同一套裝置邏輯，但 UI 走網頁、可在 Windows 執行。

必須以「管理員 / root」權限執行（tunnel 需要建立網路介面）：
  Windows: 用 run.bat（會自動以系統管理員身分重啟）
  macOS/Linux: sudo python3 app.py
"""
import json
import os
import platform
import queue
import re
import shutil
import subprocess
import tempfile
import sys
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8765
APP_DIR = Path(__file__).resolve().parent
STATE_DIR = Path.home() / ".fakegps"
STATE_DIR.mkdir(exist_ok=True)
BOOKMARKS = STATE_DIR / "bookmarks.json"
RECENTS = STATE_DIR / "recents.json"
ROUTE_GPX = STATE_DIR / "route.gpx"
IS_WIN = platform.system() == "Windows"
PYEXE = sys.executable

# 執行期狀態
_tunnel = {"proc": None, "host": None, "port": None, "step": None}
_sim = {"proc": None, "err": None, "started": None, "duration": None}
_last = {"lat": None, "lon": None}  # 最近一次送出的位置，路線的預設起點


# ───────── shell ─────────
def run(args, timeout=90):
    try:
        p = subprocess.run(pmd3(*args),
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def detect_devices():
    """用 usbmux list（跨平台，免 libimobiledevice）列出裝置；有 USB 的只列 USB。"""
    rc, out, _ = run(["usbmux", "list"])
    if rc != 0:
        return []
    try:
        devs = json.loads(out)
    except Exception:  # noqa: BLE001
        return []
    usb = [d for d in devs if d.get("ConnectionType") == "USB"] or devs
    return [{"udid": d.get("Identifier"), "name": d.get("DeviceName") or d.get("Identifier"),
             "version": d.get("ProductVersion")} for d in usb]


DEVICE_TTL = 15  # 秒；status 輪詢最多這麼久才重跑一次 usbmux list
_dev = {"list": [], "at": None, "udid": None}  # udid：使用者選的裝置，None＝第一台


def device(fresh=False):
    """回傳選定（或第一台）裝置。快取偵測結果，避免每次輪詢都開一個 pymobiledevice3 子程序。"""
    if fresh or _dev["at"] is None or time.monotonic() - _dev["at"] > DEVICE_TTL:
        _dev.update(list=detect_devices(), at=time.monotonic())
    devs = _dev["list"]
    return next((d for d in devs if d["udid"] == _dev["udid"]), devs[0] if devs else None)


def select_device(udid):
    if proc_alive(_tunnel["proc"]) and _tunnel["host"]:
        return {"ok": False, "error": "已連線中，無法切換裝置（請重新啟動程式後再選）"}
    if not any(d["udid"] == udid for d in _dev["list"]):
        return {"ok": False, "error": "找不到這台裝置"}
    _dev["udid"] = udid
    return {"ok": True}


def proc_alive(p):
    return p is not None and p.poll() is None


# ───────── geocode（curl，Win10+/mac/linux 都有）─────────
def _curl_json(url, timeout=15):
    curl = shutil.which("curl") or shutil.which("curl.exe")
    if curl:
        p = subprocess.run([curl, "-fsS", "-A", "FakeGPS", url], capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip() or "curl failed")
        return json.loads(p.stdout)
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "FakeGPS"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def geocode(q, limit=8):
    enc = urllib.parse.quote(q)
    results, seen = [], set()
    try:
        d = _curl_json(f"https://photon.komoot.io/api/?q={enc}&limit={limit}&lang=default")
        for f in d.get("features", []):
            c = f["geometry"]["coordinates"]
            pr = f.get("properties", {})
            name = pr.get("name") or ""
            parts = [pr.get(k) for k in ("street", "city", "state", "country") if pr.get(k)]
            label = " · ".join([x for x in [name, ", ".join(parts)] if x]) or name
            key = (round(c[1], 4), round(c[0], 4))
            if key in seen:
                continue
            seen.add(key)
            results.append({"name": name or label, "label": label, "lat": c[1], "lon": c[0]})
    except Exception:  # noqa: BLE001
        pass
    if not results:
        try:
            d = _curl_json(f"https://nominatim.openstreetmap.org/search?q={enc}&format=json&limit={limit}")
            for r in d:
                results.append({"name": r["display_name"].split(",")[0], "label": r["display_name"],
                                "lat": float(r["lat"]), "lon": float(r["lon"])})
        except Exception:  # noqa: BLE001
            pass
    return results[:limit]


# ───────── route（OSRM 真實道路，失敗則直線）─────────
def route_coords(start, end, mode):
    profile = "foot" if mode == "walk" else "driving"
    url = (f"https://router.project-osrm.org/route/v1/{profile}/"
           f"{start[1]},{start[0]};{end[1]},{end[0]}?overview=full&geometries=geojson")
    try:
        d = _curl_json(url)
        coords = d["routes"][0]["geometry"]["coordinates"]  # [lon,lat]
        return [(c[1], c[0]) for c in coords]
    except Exception:  # noqa: BLE001
        return [tuple(start), tuple(end)]


MAX_GPX_POINTS = 5000


def gpx_points(route, mps, interval=1.0):
    """沿路線每 interval 秒取一點。回傳 (點列, 路線總長 m, 是否因點數上限被截斷)。"""
    from math import radians, sin, cos, asin, sqrt
    def dist(a, b):
        la1, lo1, la2, lo2 = map(radians, [a[0], a[1], b[0], b[1]])
        h = sin((la2-la1)/2)**2 + cos(la1)*cos(la2)*sin((lo2-lo1)/2)**2
        return 2 * 6371000 * asin(sqrt(h))
    cum = [0.0]
    for i in range(1, len(route)):
        cum.append(cum[-1] + dist(route[i-1], route[i]))
    total = cum[-1] if cum else 0
    step = max(mps * interval, 0.5)

    def interp(t):
        if t <= 0:
            return tuple(route[0])
        if t >= total:
            return tuple(route[-1])
        i = 1
        while i < len(cum) and cum[i] < t:
            i += 1
        seg = cum[i] - cum[i-1]
        f = (t - cum[i-1]) / seg if seg > 0 else 0
        a, b = route[i-1], route[i]
        return (a[0] + (b[0]-a[0])*f, a[1] + (b[1]-a[1])*f)

    # ponytail: 沿用原本 5000 點上限（每秒一點 ≈ 83 分鐘），超過就截斷並回報給前端
    n = int(total / step)
    truncated = n > MAX_GPX_POINTS
    n = min(n, MAX_GPX_POINTS)
    pts = [interp(k * step) for k in range(max(n, 1) + 1)]
    if not truncated and pts[-1] != tuple(route[-1]):
        pts.append(tuple(route[-1]))  # 原本停在離終點不到一步處，終點從未送出
    return pts, total, truncated


def make_gpx(route, mps, interval=1.0, pts=None):
    if pts is None:
        pts = gpx_points(route, mps, interval)[0]
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<gpx version="1.1" creator="FakeGPS">', "<trk><trkseg>"]
    base = time.time()
    for k, c in enumerate(pts):
        t = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(base + k * interval))
        lines.append(f'<trkpt lat="{c[0]}" lon="{c[1]}"><time>{t}</time></trkpt>')
    lines += ["</trkseg></trk>", "</gpx>"]
    return "\n".join(lines)


# ───────── 裝置動作 ─────────
def pmd3(*args):
    return [PYEXE, "-m", "pymobiledevice3", *args]


def _device_cmds(host, port, lat=None, lon=None, gpx=None):
    """組出 tunnel 建好後的 mount / set / play 指令。集中在這裡方便測參數順序。"""
    rsd = ["--rsd", host, str(port)]
    sim = ["developer", "dvt", "simulate-location"]
    return {
        "mount": pmd3("mounter", "auto-mount", *rsd),
        # --rsd 必須在 `--` 之前，否則被當成位置參數
        "set": pmd3(*sim, "set", *rsd, "--", str(lat), str(lon)),
        "play": pmd3(*sim, "play", str(gpx), *rsd),
    }


def rsd_args(tail):
    return ["developer", "dvt", "simulate-location", *tail, "--rsd", _tunnel["host"], str(_tunnel["port"])]


def _tunnel_cmds(udid):
    """不同 iOS 版本需要不同 tunnel 指令，依序嘗試。

    iOS 17.4+（含 iOS 18 / 26+）實測必須用 `lockdown start-tunnel`；舊的
    `remote start-tunnel -t usb` 在新版裝置會回 "No tunnel services discovered /
    Device is not connected"，完全建不起來（已在 Windows 11 + iPhone iOS 27 實測）。
    保留 remote 方式當作較舊 iOS 的 fallback。"""
    return [
        ["lockdown", "start-tunnel", "--udid", udid, "--script-mode"],
        ["remote", "start-tunnel", "-t", "usb", "--udid", udid, "-p", "tcp", "--script-mode"],
    ]


TUNNEL_TIMEOUT = 30

# (輸出關鍵字, 可行動的提示)；依序比對，第一個命中者勝
_HINTS = [
    (("developer mode", "developermode"), "iPhone 尚未開啟開發者模式：設定 → 隱私權與安全性 → 開發者模式，開啟後重新開機"),
    (("access is denied", "winerror 5", "permission denied", "administrator", "requires root", "sudo"), "權限不足：請用 run.bat（會自動以系統管理員身分執行）或在系統管理員終端機啟動"),
    (("pairing", "not paired", "trust"), "iPhone 未信任這台電腦：解鎖手機，在跳出的「信任這部電腦？」點信任"),
    (("wintun", "tun device", "tun interface"), "缺少 TUN 驅動：lockdown tunnel 需要 Wintun，請確認已安裝並以系統管理員執行"),
    (("no module named", "modulenotfound"), "找不到 pymobiledevice3：執行 py -m pip install -U pymobiledevice3"),
]


def hint_for(output, fallback):
    low = output.lower()
    for keys, hint in _HINTS:
        if any(k in low for k in keys):
            return hint
    return fallback


def wait_for_rsd(proc, timeout):
    """在背景執行緒讀 stdout，主執行緒用 queue.get(timeout) 等，讓期限真的生效。

    回傳 (rsd 或 None, 讀到的所有行, 失敗原因 "timeout"/"exited"/None)。
    """
    q, waiting = queue.Queue(), threading.Event()
    waiting.set()

    def pump():
        for line in proc.stdout:
            if waiting.is_set():
                q.put(line)
        q.put(None)

    threading.Thread(target=pump, daemon=True).start()
    lines, deadline = [], time.monotonic() + timeout
    try:
        while True:
            try:
                line = q.get(timeout=max(deadline - time.monotonic(), 0))
            except queue.Empty:
                return None, lines, "timeout"
            if line is None:
                return None, lines, "exited"
            lines.append(line.rstrip())
            m = re.match(r"^([0-9a-fA-F:.]+)\s+(\d+)$", line.strip())
            if m:
                return (m.group(1), m.group(2)), lines, None
    finally:
        waiting.clear()  # 之後的輸出照樣被讀掉（避免 pipe 塞住），但不再累積


def _fail(step, error, detail=""):
    _tunnel["step"] = None
    return {"ok": False, "step": step, "error": error, "detail": detail}


def start_tunnel():
    _tunnel["step"] = "detect"
    dev = device(fresh=True)
    if not dev:
        return _fail("detect", "未偵測到 iPhone（請插上 USB、解鎖、信任；Windows 需安裝 Apple 裝置 app）")

    if not (proc_alive(_tunnel["proc"]) and _tunnel["host"]):
        _tunnel["step"] = "tunnel"
        outputs, why = [], None
        for cmd in _tunnel_cmds(dev["udid"]):
            proc = subprocess.Popen(pmd3(*cmd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            _tunnel["proc"], _tunnel["host"] = proc, None
            rsd, lines, why = wait_for_rsd(proc, TUNNEL_TIMEOUT)
            if rsd:
                break
            if proc_alive(proc):
                proc.kill()
            outputs.append("$ pymobiledevice3 " + " ".join(cmd) + "\n" + "\n".join(lines))
        if not rsd:
            out = "\n\n".join(outputs)
            if why == "timeout":
                msg = f"tunnel 建立逾時（每種方式 {TUNNEL_TIMEOUT} 秒）：" + hint_for(
                    out, "確認手機已解鎖並信任、Windows 以系統管理員執行、已裝 Apple 裝置 app")
            else:
                msg = "tunnel 建立失敗（lockdown 與 remote 都試過）：" + hint_for(out, "請展開下方完整輸出查看原因")
            return _fail("tunnel", msg, out)
        _tunnel["host"], _tunnel["port"], _tunnel["dev"] = *rsd, dev

    _tunnel["step"] = "mount"
    rc, out, err = run(_device_cmds(_tunnel["host"], _tunnel["port"])["mount"][len(pmd3()):])
    if rc != 0:
        detail = (out + err).strip()
        return _fail("mount", "tunnel 已建立，但掛載開發者映像（DDI）失敗：" + hint_for(
            detail, "確認開發者模式已開啟、手機已解鎖；可再按一次連線重試"), detail)
    _tunnel["step"] = None
    return {"ok": True, "rsd": f'{_tunnel["host"]} {_tunnel["port"]}'}


def set_location(lat, lon):
    if not (proc_alive(_tunnel["proc"]) and _tunnel["host"]):
        return {"ok": False, "error": "請先連線手機"}
    stop_sim()
    proc = _spawn_sim(_device_cmds(_tunnel["host"], _tunnel["port"], lat=lat, lon=lon)["set"])
    time.sleep(1.0)
    if proc.poll() is not None and proc.returncode != 0:
        detail = _sim_error()
        return {"ok": False, "error": "設定失敗，tunnel 可能已斷：" + hint_for(detail, "請重新連線"), "detail": detail}
    _last.update(lat=lat, lon=lon)
    # 1 秒內沒報錯只代表指令已送出；無法從手機端回讀位置確認
    return {"ok": True, "confirmed": False}


def _spawn_sim(cmd):
    err = tempfile.TemporaryFile()  # 不用 PIPE：長駐程序輸出多時 pipe 會塞住
    _sim["proc"], _sim["err"] = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=err), err
    return _sim["proc"]


def _sim_error():
    if not _sim["err"]:
        return ""
    _sim["err"].seek(0)
    return _sim["err"].read().decode("utf-8", "replace").strip()


def play_route(coords, mps):
    if not (proc_alive(_tunnel["proc"]) and _tunnel["host"]):
        return {"ok": False, "error": "請先連線手機"}
    pts, total, truncated = gpx_points(coords, mps)
    ROUTE_GPX.write_text(make_gpx(coords, mps, pts=pts), encoding="utf-8")
    stop_sim()
    _spawn_sim(_device_cmds(_tunnel["host"], _tunnel["port"], gpx=ROUTE_GPX)["play"])
    _sim.update(started=time.time(), duration=len(pts) - 1, path=pts)
    _last.update(lat=pts[-1][0], lon=pts[-1][1])
    return {"ok": True, "path": pts, "distance_m": round(total), "duration_s": len(pts) - 1,
            "truncated": truncated}


def stop_sim():
    if proc_alive(_sim["proc"]):
        _sim["proc"].terminate()
        if _sim.get("path"):  # 路線中途停下：最近位置是當下走到的點，不是終點
            p = _sim["path"][min(int(time.time() - _sim["started"]), len(_sim["path"]) - 1)]
            _last.update(lat=p[0], lon=p[1])
    _sim.update(proc=None, started=None, duration=None, path=None)


def clear_location():
    stop_sim()
    if _tunnel["host"]:
        run(rsd_args(["clear"]))
    return {"ok": True}


def status():
    tunnel_up = bool(proc_alive(_tunnel["proc"]) and _tunnel["host"])
    # tunnel 活著就代表裝置在，不必再偵測；否則用快取（最多 DEVICE_TTL 秒重偵測一次）
    dev = _tunnel.get("dev") if tunnel_up else device()
    return {
        "os": platform.system(),
        "device_connected": bool(dev),
        "device_name": dev["name"] if dev else None,
        "device_udid": dev["udid"] if dev else None,
        "devices": _dev["list"],
        "tunnel_up": tunnel_up,
        "simulating": bool(proc_alive(_sim["proc"])),
        "step": _tunnel["step"],
        "last": _last if _last["lat"] is not None else None,
        "route_elapsed": round(time.time() - _sim["started"]) if _sim["started"] and proc_alive(_sim["proc"]) else None,
        "route_duration": _sim["duration"] if proc_alive(_sim["proc"]) else None,
    }


# ───────── bookmarks/recents ─────────
def jload(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return []


def jsave(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


# ───────── HTTP ─────────
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n).decode()) if n else {}

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/index.html"):
            return self._send(200, (APP_DIR / "index.html").read_text(encoding="utf-8"), "text/html")
        if u.path == "/api/status":
            return self._send(200, status())
        if u.path == "/api/bookmarks":
            return self._send(200, {"bookmarks": jload(BOOKMARKS), "recents": jload(RECENTS)})
        if u.path == "/api/search":
            q = urllib.parse.parse_qs(u.query).get("q", [""])[0]
            return self._send(200, {"results": geocode(q) if q.strip() else []})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        try:
            b = self._body()
            if u.path == "/api/start":
                return self._send(200, start_tunnel())
            if u.path == "/api/select":
                return self._send(200, select_device(b.get("udid")))
            if u.path == "/api/set":
                r = set_location(b["lat"], b["lon"])
                if r.get("ok") and not b.get("nudge"):  # 搖桿微調不灌爆「最近使用」
                    rec = jload(RECENTS)
                    rec = [x for x in rec if abs(x["lat"]-b["lat"]) > 1e-5 or abs(x["lon"]-b["lon"]) > 1e-5]
                    rec.insert(0, {"name": b.get("label", ""), "lat": b["lat"], "lon": b["lon"]})
                    jsave(RECENTS, rec[:12])
                return self._send(200, r)
            if u.path == "/api/clear":
                return self._send(200, clear_location())
            if u.path == "/api/stop":
                stop_sim()
                return self._send(200, {"ok": True})
            if u.path == "/api/route":
                start = (b["slat"], b["slon"]) if b.get("slat") is not None else (_last["lat"], _last["lon"])
                if start[0] is None:
                    return self._send(200, {"ok": False, "error": "沒有起點：先設定一次位置，或用「設為起點」"})
                coords = route_coords(start, (b["elat"], b["elon"]), b.get("mode", "walk"))
                mps = {"walk": 1.4, "bike": 5.5, "drive": 13.9}.get(b.get("mode", "walk"), 1.4)
                return self._send(200, play_route(coords, mps))
            if u.path == "/api/bookmarks/add":
                bm = [x for x in jload(BOOKMARKS) if x["name"] != b["name"]]
                bm.append({"name": b["name"], "lat": b["lat"], "lon": b["lon"]})
                jsave(BOOKMARKS, bm)
                return self._send(200, {"ok": True})
            if u.path == "/api/bookmarks/del":
                jsave(BOOKMARKS, [x for x in jload(BOOKMARKS) if x["name"] != b["name"]])
                return self._send(200, {"ok": True})
        except Exception as e:  # noqa: BLE001
            return self._send(200, {"ok": False, "error": str(e)})
        return self._send(404, {"error": "not found"})


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    url = f"http://127.0.0.1:{PORT}/"
    print(f"FakeGPS 伺服器: {url}  (OS: {platform.system()})")
    try:
        webbrowser.open(url)
    except Exception:  # noqa: BLE001
        pass
    srv.serve_forever()


if __name__ == "__main__":
    main()
