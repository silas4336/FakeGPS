#!/usr/bin/env bash
#
# doctor.sh — 診斷 FakeGPS 執行環境，列出每一項是否就緒。
#
cd "$(dirname "$0")" || exit 1
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
FAIL=0

printf '\033[1m📍 FakeGPS 環境診斷\033[0m\n\n'

# 系統
[ "$(uname)" = "Darwin" ] && ok "macOS $(sw_vers -productVersion)" || bad "非 macOS"

# 工具鏈
command -v swiftc >/dev/null && ok "swiftc $(swiftc --version 2>/dev/null | head -1 | awk '{print $4}')" \
  || bad "swiftc 缺少 → xcode-select --install"
command -v brew >/dev/null && ok "Homebrew" || bad "Homebrew 缺少 → https://brew.sh"

# 相依
ID="$( { command -v idevice_id || ls /opt/homebrew/bin/idevice_id /usr/local/bin/idevice_id; } 2>/dev/null | head -1)"
[ -n "$ID" ] && ok "libimobiledevice（$ID）" || bad "libimobiledevice 缺少 → brew install libimobiledevice"

PY="$(command -v python3)"
if [ -n "$PY" ] && "$PY" -c "import pymobiledevice3" 2>/dev/null; then
  ok "pymobiledevice3（$("$PY" -V 2>&1)）"
else
  bad "pymobiledevice3 缺少 → python3 -m pip install --user -U pymobiledevice3"
fi

# 權限設定
[ -x /usr/local/libexec/fakegps_tunnel.sh ] && ok "tunnel helper 已安裝" || bad "tunnel helper 缺少 → 執行 ./install.sh"
if sudo -n /usr/local/libexec/fakegps_tunnel.sh stop 2>/dev/null; then
  ok "免密碼權限正常"
else
  bad "免密碼權限未設定 → 執行 ./install.sh"
fi

# App
[ -d /Applications/FakeGPS.app ] && ok "FakeGPS.app 已安裝於 /Applications" || warn "App 尚未安裝到 /Applications（執行 ./install.sh）"

# 裝置（選擇性）
if [ -n "$ID" ]; then
  UDID="$("$ID" -l 2>/dev/null | head -1)"
  [ -n "$UDID" ] && ok "偵測到 iPhone（$UDID）" || warn "目前未偵測到 iPhone（插上 USB、解鎖、信任）"
fi

echo
if [ "$FAIL" = 0 ]; then
  printf '\033[1;32m全部就緒，可以開 FakeGPS 了！\033[0m\n'
else
  printf '\033[1;31m有項目未就緒，依上面提示處理，或直接執行 ./install.sh\033[0m\n'
  exit 1
fi
