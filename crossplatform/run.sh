#!/usr/bin/env bash
# FakeGPS (macOS / Linux) — tunnel 需要 root
cd "$(dirname "$0")"
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }
python3 -c "import pymobiledevice3" 2>/dev/null || python3 -m pip install -U pymobiledevice3
exec sudo python3 app.py
