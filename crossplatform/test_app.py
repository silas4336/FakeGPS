"""crossplatform/app.py 的單元測試（只用標準庫）。執行：cd crossplatform && py -m unittest -v"""
import re
import unittest

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

if __name__ == "__main__":
    unittest.main()
