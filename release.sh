#!/usr/bin/env bash
#
# release.sh — 打包成可下載的單一 zip：預編 Universal App + 安裝器。
# 使用者只要下載這個 zip、解壓、跑 install.sh（不需 Xcode、不用編譯）。
#
# 用法: ./release.sh [版本]      例: ./release.sh v1.0.0
#
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:-v1.0.0}"
STAGE="$(mktemp -d)/FakeGPS"
OUT="dist"
ZIP="$OUT/FakeGPS-$VER.zip"

echo "▸ 編譯 Universal App…"
./build.sh ./build >/dev/null

echo "▸ 組裝 release 內容…"
mkdir -p "$STAGE" "$OUT"
cp -R ./build/FakeGPS.app "$STAGE/FakeGPS.app"
cp install.sh uninstall.sh doctor.sh LICENSE "$STAGE/"
# release 版 README：精簡的安裝指引
cat > "$STAGE/README.txt" <<EOF
FakeGPS $VER
============

安裝（一行）:
  1. 解壓這個資料夾
  2. 打開「終端機」，把這個資料夾拖進去 cd 進來，或直接：
       cd ~/Downloads/FakeGPS
  3. 執行: ./install.sh

install.sh 會自動安裝相依（Homebrew / libimobiledevice / pymobiledevice3）、
設定免密碼 tunnel 權限，並把 FakeGPS.app 裝到 /Applications。

需求: macOS 14+、iPhone 開啟開發者模式。
專案首頁: https://github.com/silas4336/FakeGPS
解除安裝: ./uninstall.sh
EOF

echo "▸ 壓縮…"
rm -f "$ZIP"
( cd "$(dirname "$STAGE")" && zip -qr -X "$OLDPWD/$ZIP" "FakeGPS" )
rm -rf "$(dirname "$STAGE")"

echo "✓ 完成：$ZIP"
du -h "$ZIP" | cut -f1 | xargs echo "  大小:"
