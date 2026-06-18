#!/usr/bin/env bash
# uninstall.sh — 移除 FakeGPS、helper 與 sudoers 規則
set -euo pipefail
say() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }

say "停止執行中的模擬與 tunnel…"
pkill -f "MacOS/FakeGPS" 2>/dev/null || true
sudo -n /usr/local/libexec/fakegps_tunnel.sh stop 2>/dev/null || true

say "移除檔案（需要 sudo）…"
sudo rm -f /usr/local/libexec/fakegps_tunnel.sh
sudo rm -f /etc/sudoers.d/fakegps
rm -rf "/Applications/FakeGPS.app"

read -r -p "也要刪除設定與書籤 ~/.fakegps 嗎？[y/N] " ans
[[ "${ans:-N}" =~ ^[Yy]$ ]] && rm -rf "$HOME/.fakegps"

printf '\033[1;32m✓ 已解除安裝\033[0m\n'
