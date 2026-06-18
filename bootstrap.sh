#!/usr/bin/env bash
#
# bootstrap.sh — 一行安裝：clone repo 再執行 install.sh
#
# 用法（repo 公開後）:
#   curl -fsSL https://raw.githubusercontent.com/silas4336/FakeGPS/main/bootstrap.sh | bash
#
set -euo pipefail
REPO="https://github.com/silas4336/FakeGPS.git"
DEST="${FAKEGPS_DIR:-$HOME/FakeGPS}"

echo "▸ 取得 FakeGPS 原始碼到 $DEST…"
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" pull --ff-only
else
  git clone --depth 1 "$REPO" "$DEST"
fi
cd "$DEST"
exec ./install.sh
