"""crossplatform/app.py 的單元測試（只用標準庫）。執行：cd crossplatform && py -m unittest -v"""
import os
import re
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

import app

LAT0, LON0 = 25.0, 121.5
LAT1 = 25.001  # 往北 0.001 度 ≈ 111.19 m


def trkpts(gpx):
    return [(float(a), float(b)) for a, b in re.findall(r'<trkpt lat="([^"]+)" lon="([^"]+)"', gpx)]


class MakeGpxTest(unittest.TestCase):
    def test_interpolates_along_route_at_speed(self):
        pts = trkpts(app.make_gpx([(LAT0, LON0), (LAT1, LON0)], mps=1.4))
        self.assertEqual(pts[0], (LAT0, LON0))
        # 111.19 m / 1.4 m/s → 每秒一點，79 步 + 起點
        self.assertGreaterEqual(len(pts), 80)
        step = pts[1][0] - pts[0][0]
        self.assertAlmostEqual(step * 111195, 1.4, places=1)
        self.assertTrue(all(b[0] >= a[0] for a, b in zip(pts, pts[1:])))

    def test_single_point_route(self):
        pts = trkpts(app.make_gpx([(LAT0, LON0)], mps=1.4))
        self.assertTrue(pts and all(p == (LAT0, LON0) for p in pts))

    def test_timestamps_one_second_apart(self):
        gpx = app.make_gpx([(LAT0, LON0), (LAT1, LON0)], mps=13.9)
        times = re.findall(r"<time>([^<]+)</time>", gpx)
        self.assertEqual(len(times), len(trkpts(gpx)))
        self.assertEqual(len(set(times)), len(times))


class TunnelCmdsTest(unittest.TestCase):
    def test_set_puts_rsd_before_double_dash(self):
        cmd = app._device_cmds("fd00::1", 51234, lat=-33.8, lon=151.2)["set"]
        self.assertLess(cmd.index("--rsd"), cmd.index("--"))
        self.assertEqual(cmd[cmd.index("--rsd"):], ["--rsd", "fd00::1", "51234", "--", "-33.8", "151.2"])

    def test_tunnel_tries_lockdown_first_then_remote(self):
        # CLAUDE.md：iOS 17.4+ 實測必須用 lockdown start-tunnel，remote 只當舊 iOS 的 fallback
        lockdown, remote = app._tunnel_cmds("UDID-1")
        self.assertEqual(lockdown[:2], ["lockdown", "start-tunnel"])
        self.assertEqual(remote[:2], ["remote", "start-tunnel"])
        for cmd in (lockdown, remote):
            self.assertEqual(cmd[cmd.index("--udid") + 1], "UDID-1")
            self.assertIn("--script-mode", cmd)
        self.assertEqual(remote[remote.index("-p") + 1], "tcp")

    def test_mount_and_play_carry_rsd(self):
        c = app._device_cmds("fd00::1", 51234, gpx="r.gpx")
        self.assertEqual(c["mount"][-3:], ["--rsd", "fd00::1", "51234"])
        self.assertEqual(c["play"][-4:], ["r.gpx", "--rsd", "fd00::1", "51234"])


FAKE = str(Path(__file__).resolve().parent / "devtools" / "fake_pmd3")


def py_proc(code):
    return subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)


class WaitForRsdTest(unittest.TestCase):
    def test_deadline_applies_even_when_child_is_silent(self):
        p = py_proc("import time;print('starting',flush=True);time.sleep(30)")
        t = time.monotonic()
        rsd, lines, why = app.wait_for_rsd(p, 1)
        p.kill()
        self.assertLess(time.monotonic() - t, 3)
        self.assertEqual((rsd, why, lines), (None, "timeout", ["starting"]))

    def test_exit_returns_full_output(self):
        p = py_proc("print('a');print('b');raise SystemExit(1)")
        rsd, lines, why = app.wait_for_rsd(p, 5)
        self.assertEqual((rsd, why, lines), (None, "exited", ["a", "b"]))

    def test_parses_host_port(self):
        p = py_proc("import time;print('log');print('fd00::1 51234',flush=True);time.sleep(30)")
        rsd, _, why = app.wait_for_rsd(p, 5)
        p.kill()
        self.assertEqual((rsd, why), (("fd00::1", "51234"), None))


class HintTest(unittest.TestCase):
    def test_known_errors_map_to_actions(self):
        self.assertIn("開發者模式", app.hint_for("DeveloperModeIsNotEnabledError", "x"))
        self.assertIn("系統管理員", app.hint_for("PermissionError: [WinError 5] Access is denied", "x"))
        self.assertEqual(app.hint_for("INFO starting tunnel", "fallback"), "fallback")


@mock.patch.dict(os.environ, {"PYTHONPATH": FAKE})
class StartTunnelWithFakeTest(unittest.TestCase):
    def tearDown(self):
        if app.proc_alive(app._tunnel["proc"]):
            app._tunnel["proc"].kill()
        app._tunnel.update(proc=None, host=None, port=None, step=None)

    def test_ok_runs_mount(self):
        r = app.start_tunnel()
        self.assertEqual(r, {"ok": True, "rsd": "fd00::1 51234"})

    def test_failure_reports_step_hint_and_full_output(self):
        with mock.patch.dict(os.environ, {"FAKE_TUNNEL": "fail"}):
            r = app.start_tunnel()
        self.assertEqual(r["step"], "tunnel")
        self.assertIn("開發者模式", r["error"])
        # 兩種 tunnel 都試過，完整輸出都要回給使用者
        self.assertIn("$ pymobiledevice3 lockdown start-tunnel", r["detail"])
        self.assertIn("$ pymobiledevice3 remote start-tunnel", r["detail"])
        self.assertIn("DeveloperModeIsNotEnabledError", r["detail"])

    def test_falls_back_to_remote_when_lockdown_fails(self):
        with mock.patch.dict(os.environ, {"FAKE_LOCKDOWN": "fail"}), \
                mock.patch.object(app.subprocess, "Popen", wraps=app.subprocess.Popen) as po:
            r = app.start_tunnel()
        self.assertTrue(r["ok"])
        tunnels = [c.args[0][3] for c in po.call_args_list if "start-tunnel" in c.args[0]]
        self.assertEqual(tunnels, ["lockdown", "remote"])

    def test_hang_times_out(self):
        with mock.patch.dict(os.environ, {"FAKE_TUNNEL": "hang"}), mock.patch.object(app, "TUNNEL_TIMEOUT", 2):
            t = time.monotonic()
            r = app.start_tunnel()
        self.assertLess(time.monotonic() - t, 10)
        self.assertEqual(r["step"], "tunnel")
        self.assertIn("逾時", r["error"])


class GpxEndpointTest(unittest.TestCase):
    def test_route_ends_exactly_at_destination(self):
        pts, total, truncated = app.gpx_points([(LAT0, LON0), (LAT1, LON0)], 1.4)
        self.assertEqual(pts[-1], (LAT1, LON0))
        self.assertAlmostEqual(total, 111.19, places=1)
        self.assertFalse(truncated)

    def test_long_route_reports_truncation(self):
        pts, _, truncated = app.gpx_points([(LAT0, LON0), (LAT0 + 1, LON0)], 1.4)
        self.assertTrue(truncated)
        self.assertEqual(len(pts), app.MAX_GPX_POINTS + 1)


@mock.patch.dict(os.environ, {"PYTHONPATH": FAKE})
class MovementWithFakeTest(unittest.TestCase):
    """用假 pymobiledevice3 跑 HTTP 端點：set → route（預設起點）→ stop。"""

    @classmethod
    def setUpClass(cls):
        import tempfile
        import threading
        from http.server import ThreadingHTTPServer
        cls.tmp = Path(tempfile.mkdtemp())
        cls.patches = [mock.patch.object(app, n, cls.tmp / f) for n, f in
                       (("RECENTS", "r.json"), ("BOOKMARKS", "b.json"), ("ROUTE_GPX", "r.gpx"))]
        cls.patches.append(mock.patch.object(app, "route_coords", lambda s, e, m: [tuple(s), tuple(e)]))
        for p in cls.patches:
            p.start()
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), app.H)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        for p in cls.patches:
            p.stop()

    def tearDown(self):
        app.stop_sim()
        if app.proc_alive(app._tunnel["proc"]):
            app._tunnel["proc"].kill()
        app._tunnel.update(proc=None, host=None, port=None, step=None)
        app._last.update(lat=None, lon=None)

    def post(self, path, body=None):
        import json
        import urllib.request
        req = urllib.request.Request(f"http://127.0.0.1:{self.srv.server_port}{path}",
                                     data=json.dumps(body or {}).encode(),
                                     headers={"Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req))

    def test_route_without_start_or_last_position_errors(self):
        r = self.post("/api/route", {"elat": LAT1, "elon": LON0})
        self.assertFalse(r["ok"])
        self.assertIn("沒有起點", r["error"])

    def test_set_then_route_from_last_position_then_stop(self):
        self.assertTrue(self.post("/api/start")["ok"])
        r = self.post("/api/set", {"lat": LAT0, "lon": LON0})
        self.assertEqual(r, {"ok": True, "confirmed": False})
        r = self.post("/api/route", {"elat": LAT1, "elon": LON0, "mode": "walk"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["path"][0], [LAT0, LON0])
        self.assertEqual(r["path"][-1], [LAT1, LON0])
        self.assertEqual(r["duration_s"], len(r["path"]) - 1)
        st = app.status()
        self.assertTrue(st["simulating"])
        self.assertEqual(st["route_duration"], r["duration_s"])
        self.assertEqual(self.post("/api/stop"), {"ok": True})
        self.assertFalse(app.status()["simulating"])
        # 剛開始就停 → 最近位置應在起點附近，而非終點
        self.assertAlmostEqual(app._last["lat"], LAT0, places=4)


class StatusPollingTest(unittest.TestCase):
    def setUp(self):
        app._dev.update(info=None, at=None)

    tearDown = setUp

    def test_status_reuses_cached_device(self):
        dev = {"udid": "U", "name": "N", "version": "18"}
        with mock.patch.object(app, "detect_device", return_value=dev) as det:
            for _ in range(5):
                self.assertEqual(app.status()["device_name"], "N")
        self.assertEqual(det.call_count, 1)

    def test_cache_expires_and_connect_forces_fresh(self):
        with mock.patch.object(app, "detect_device", return_value=None) as det:
            app.status()
            app._dev["at"] -= app.DEVICE_TTL + 1
            app.status()
            self.assertEqual(det.call_count, 2)
            app.start_tunnel()
            self.assertEqual(det.call_count, 3)


if __name__ == "__main__":
    unittest.main()
