#!/usr/bin/env bash
# FakeGPS (macOS / Linux) — tunnel 需要 root
cd "$(dirname "$0")"
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }
python3 -m pip install -q -r requirements.txt  # 版本鎖在 requirements.txt
exec sudo python3 app.py
