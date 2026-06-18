#!/usr/bin/env bash
# build.sh — 把 FakeGPS.swift 編成 Universal (arm64 + x86_64) 的 .app
# 用法: ./build.sh [輸出目錄]   （預設 ./build）
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-./build}"
NAME="FakeGPS"
MIN_OS="14.0"
APP="$OUT/$NAME.app"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

echo "▸ 編譯 arm64…"
swiftc -O -parse-as-library -target arm64-apple-macosx$MIN_OS FakeGPS.swift \
  -o "$TMP/$NAME-arm64" -framework SwiftUI -framework MapKit -framework AppKit
echo "▸ 編譯 x86_64…"
swiftc -O -parse-as-library -target x86_64-apple-macosx$MIN_OS FakeGPS.swift \
  -o "$TMP/$NAME-x86_64" -framework SwiftUI -framework MapKit -framework AppKit
echo "▸ 合併成 Universal binary…"
lipo -create -output "$TMP/$NAME" "$TMP/$NAME-arm64" "$TMP/$NAME-x86_64"
lipo -archs "$TMP/$NAME"

echo "▸ 組裝 .app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/$NAME" "$APP/Contents/MacOS/$NAME"

# 圖示
if [[ -f icon.svg ]]; then
  qlmanage -t -s 1024 -o "$TMP" icon.svg >/dev/null 2>&1 || true
  PNG="$(ls "$TMP"/*.png 2>/dev/null | head -1 || true)"
  if [[ -n "$PNG" ]]; then
    ICONSET="$TMP/$NAME.iconset"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
      sips -z $s $s "$PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
      sips -z $((s*2)) $((s*2)) "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.fakegps.app</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "✓ 完成：$APP"
