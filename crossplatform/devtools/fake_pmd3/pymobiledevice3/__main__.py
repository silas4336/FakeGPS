"""假的 pymobiledevice3 CLI（只供無 iPhone 時開發/測試 UI 用，可整個 devtools/ 刪掉）。

環境變數：
  FAKE_DEVICES  usbmux list 回幾台（預設 1）
  FAKE_TUNNEL   ok | fail | hang | slow（預設 ok，lockdown/remote 兩種 start-tunnel 都套用）
  FAKE_LOCKDOWN fail → 只有 lockdown start-tunnel 失敗（測 remote fallback）
  FAKE_LOG      每次呼叫把 argv 附加寫到這個檔
"""
import json
import os
import sys
import time

argv = sys.argv[1:]
if os.environ.get("FAKE_LOG"):
    with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as f:
        f.write(json.dumps(argv) + "\n")

if argv[:2] == ["usbmux", "list"]:
    n = int(os.environ.get("FAKE_DEVICES", "1"))
    print(json.dumps([{"Identifier": f"0000FAKE-{i}", "DeviceName": f"Fake iPhone {i}",
                       "ProductVersion": "18.1", "ConnectionType": "USB"} for i in range(1, n + 1)]))
elif argv[1:2] == ["start-tunnel"] and argv[0] in ("lockdown", "remote"):
    mode = os.environ.get("FAKE_TUNNEL", "ok")
    print(f"INFO starting {argv[0]} tunnel", flush=True)
    if argv[0] == "lockdown" and os.environ.get("FAKE_LOCKDOWN") == "fail":
        print("ERROR No tunnel services discovered", flush=True)
        sys.exit(1)
    if mode == "fail":
        print("ERROR Device is not in developer mode", flush=True)
        print("pymobiledevice3.exceptions.DeveloperModeIsNotEnabledError", flush=True)
        sys.exit(1)
    if mode == "hang":
        time.sleep(3600)
    if mode == "slow":
        time.sleep(3)
    print("fd00::1 51234", flush=True)
    time.sleep(3600)
elif argv[:2] == ["mounter", "auto-mount"]:
    print("DeveloperDiskImage already mounted")
elif argv[:3] == ["developer", "dvt", "simulate-location"]:
    sub = argv[3]
    if sub == "set":
        rest = argv[4:]
        if "--" not in rest or rest.index("--rsd") > rest.index("--"):
            print("Got unexpected extra argument", file=sys.stderr)
            sys.exit(2)
        time.sleep(3600)
    elif sub == "play":
        time.sleep(3600)
    # clear: 直接成功
else:
    print(f"fake pymobiledevice3: unsupported {argv}", file=sys.stderr)
    sys.exit(2)
