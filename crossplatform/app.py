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
import re
import shutil
import subprocess
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
_tunnel = {"proc": None, "host": None, "port": None}
_sim = {"proc": None}


# ───────── shell ─────────
def run(args, timeout=90):
    try:
        p = subprocess.run([PYEXE, "-m", "pymobiledevice3", *args],
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def detect_device():
    """用 usbmux list（跨平台，免 libimobiledevice）取第一台裝置。"""
    rc, out, _ = run(["usbmux", "list"])
    if rc != 0:
        return None
    try:
        devs = json.loads(out)
    except Exception:  # noqa: BLE001
        return None
    usb = [d for d in devs if d.get("ConnectionType") == "USB"] or devs
    if not usb:
        return None
    d = usb[0]
    return {"udid": d.get("Identifier"), "name": d.get("DeviceName") or d.get("Identifier"),
            "version": d.get("ProductVersion")}


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


def make_gpx(route, mps, interval=1.0):
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
            return route[0]
        if t >= total:
            return route[-1]
        i = 1
        while i < len(cum) and cum[i] < t:
            i += 1
        seg = cum[i] - cum[i-1]
        f = (t - cum[i-1]) / seg if seg > 0 else 0
        a, b = route[i-1], route[i]
        return (a[0] + (b[0]-a[0])*f, a[1] + (b[1]-a[1])*f)

    n = min(int(total / step), 5000)
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<gpx version="1.1" creator="FakeGPS">', "<trk><trkseg>"]
    base = time.time()
    for k in range(max(n, 1) + 1):
        c = interp(k * step)
        t = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(base + k * interval))
        lines.append(f'<trkpt lat="{c[0]}" lon="{c[1]}"><time>{t}</time></trkpt>')
    lines += ["</trkseg></trk>", "</gpx>"]
    return "\n".join(lines)


# ───────── 裝置動作 ─────────
def rsd_args(tail):
    return ["developer", "dvt", "simulate-location", *tail, "--rsd", _tunnel["host"], str(_tunnel["port"])]


def start_tunnel():
    dev = detect_device()
    if not dev:
        return {"ok": False, "error": "未偵測到 iPhone（請插上 USB、解鎖、信任；Windows 需安裝 Apple 裝置 app）"}
    if proc_alive(_tunnel["proc"]) and _tunnel["host"]:
        return {"ok": True, "rsd": f'{_tunnel["host"]} {_tunnel["port"]}'}

    proc = subprocess.Popen(
        [PYEXE, "-m", "pymobiledevice3", "remote", "start-tunnel",
         "-t", "usb", "--udid", dev["udid"], "-p", "tcp", "--script-mode"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    _tunnel["proc"] = proc

    rsd = None
    deadline = time.time() + 30
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                break
            continue
        m = re.match(r"^([0-9a-fA-F:]+)\s+(\d+)$", line.strip())
        if m:
            rsd = (m.group(1), m.group(2))
            break
    if not rsd:
        return {"ok": False, "error": "tunnel 建立失敗或逾時（Windows 請確認以系統管理員執行、已裝 WinTUN/Apple 裝置）"}
    _tunnel["host"], _tunnel["port"] = rsd
    # 繼續吞掉後續輸出避免阻塞
    threading.Thread(target=lambda: [None for _ in proc.stdout], daemon=True).start()
    run(rsd_args_mount())
    return {"ok": True, "rsd": f"{rsd[0]} {rsd[1]}"}


def rsd_args_mount():
    return ["mounter", "auto-mount", "--rsd", _tunnel["host"], str(_tunnel["port"])]


def set_location(lat, lon):
    if not (proc_alive(_tunnel["proc"]) and _tunnel["host"]):
        return {"ok": False, "error": "請先連線手機"}
    stop_sim()
    # --rsd 必須在 `--` 之前
    proc = subprocess.Popen(
        [PYEXE, "-m", "pymobiledevice3", "developer", "dvt", "simulate-location",
         "set", "--rsd", _tunnel["host"], str(_tunnel["port"]), "--", str(lat), str(lon)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    _sim["proc"] = proc
    time.sleep(1.0)
    if proc.poll() is not None:
        return {"ok": False, "error": "設定失敗，tunnel 可能已斷"}
    return {"ok": True}


def play_route(coords, mps):
    if not (proc_alive(_tunnel["proc"]) and _tunnel["host"]):
        return {"ok": False, "error": "請先連線手機"}
    ROUTE_GPX.write_text(make_gpx(coords, mps), encoding="utf-8")
    stop_sim()
    proc = subprocess.Popen(
        [PYEXE, "-m", "pymobiledevice3", "developer", "dvt", "simulate-location",
         "play", str(ROUTE_GPX), "--rsd", _tunnel["host"], str(_tunnel["port"])],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    _sim["proc"] = proc
    return {"ok": True}


def stop_sim():
    if proc_alive(_sim["proc"]):
        _sim["proc"].terminate()
    _sim["proc"] = None


def clear_location():
    stop_sim()
    if _tunnel["host"]:
        run(rsd_args(["clear"]))
    return {"ok": True}


def status():
    dev = detect_device()
    return {
        "os": platform.system(),
        "device_connected": bool(dev),
        "device_name": dev["name"] if dev else None,
        "tunnel_up": bool(proc_alive(_tunnel["proc"]) and _tunnel["host"]),
        "simulating": bool(proc_alive(_sim["proc"])),
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
            if u.path == "/api/set":
                r = set_location(b["lat"], b["lon"])
                if r.get("ok"):
                    rec = jload(RECENTS)
                    rec = [x for x in rec if abs(x["lat"]-b["lat"]) > 1e-5 or abs(x["lon"]-b["lon"]) > 1e-5]
                    rec.insert(0, {"name": b.get("label", ""), "lat": b["lat"], "lon": b["lon"]})
                    jsave(RECENTS, rec[:12])
                return self._send(200, r)
            if u.path == "/api/clear":
                return self._send(200, clear_location())
            if u.path == "/api/route":
                coords = route_coords((b["slat"], b["slon"]), (b["elat"], b["elon"]), b.get("mode", "walk"))
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
