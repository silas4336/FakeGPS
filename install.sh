#!/usr/bin/env bash
#
# install.sh — 安裝 FakeGPS 及其相依套件、設定免密碼 tunnel 權限，並把 App 裝到 /Applications
#
# 流程：檢查工具鏈 → 安裝相依（libimobiledevice / pymobiledevice3）→ 偵測路徑寫入 config
#       → 編譯 Universal App → 建立 root helper + NOPASSWD sudoers（用當前使用者）→ 安裝到 /Applications
#
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

USER_NAME="$(whoami)"
STATE_DIR="$HOME/.fakegps"
HELPER="/usr/local/libexec/fakegps_tunnel.sh"
SUDOERS="/etc/sudoers.d/fakegps"

# 1) 工具鏈
say "檢查工具鏈…"
command -v swiftc >/dev/null || die "找不到 swiftc，請先安裝 Xcode Command Line Tools：xcode-select --install"
command -v brew >/dev/null || die "找不到 Homebrew，請先安裝：https://brew.sh"

# 2) 相依：libimobiledevice
if ! command -v idevice_id >/dev/null && [ ! -x /opt/homebrew/bin/idevice_id ] && [ ! -x /usr/local/bin/idevice_id ]; then
  say "安裝 libimobiledevice…"
  brew install libimobiledevice
fi
IDEVICE_ID="$(command -v idevice_id || echo /opt/homebrew/bin/idevice_id)"
IDEVICEINFO="$(command -v ideviceinfo || echo /opt/homebrew/bin/ideviceinfo)"
[ -x "$IDEVICE_ID" ] || IDEVICE_ID="$(ls /opt/homebrew/bin/idevice_id /usr/local/bin/idevice_id 2>/dev/null | head -1)"
[ -x "$IDEVICEINFO" ] || IDEVICEINFO="$(ls /opt/homebrew/bin/ideviceinfo /usr/local/bin/ideviceinfo 2>/dev/null | head -1)"

# 3) Python + pymobiledevice3
say "設定 Python 與 pymobiledevice3…"
PYTHON="$(command -v python3)"
[ -n "$PYTHON" ] || die "找不到 python3"
"$PYTHON" -m pip install --user -q -U pymobiledevice3 || die "pymobiledevice3 安裝失敗"
ok "pymobiledevice3 已安裝（$("$PYTHON" -V 2>&1)）"

# 4) 寫設定檔（App 與 helper 都會讀路徑）
say "寫入設定 $STATE_DIR/config…"
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/config" <<CFG
python=$PYTHON
idevice_id=$IDEVICE_ID
ideviceinfo=$IDEVICEINFO
helper=$HELPER
CFG

# 5) 編譯 Universal App
say "編譯 App（Universal）…"
./build.sh ./build

# 6) root helper + NOPASSWD sudoers（需要 sudo 一次）
say "設定免密碼 tunnel 權限（需要輸入一次密碼）…"
TMP_HELPER="$(mktemp)"
cat > "$TMP_HELPER" <<HELPER_EOF
#!/bin/bash
# FakeGPS tunnel helper — 由 $SUDOERS 授權免密碼執行
PY="$PYTHON"
case "\$1" in
  stop) pkill -f "pymobiledevice3 remote start-tunnel" 2>/dev/null; exit 0;;
esac
UDID="\$1"
if ! [[ "\$UDID" =~ ^[0-9A-Fa-f-]+\$ ]]; then echo "bad udid" >&2; exit 1; fi
pkill -f "pymobiledevice3 remote start-tunnel" 2>/dev/null
sleep 1
exec "\$PY" -m pymobiledevice3 remote start-tunnel -t usb --udid "\$UDID" -p tcp --script-mode
HELPER_EOF

TMP_SUDO="$(mktemp)"
echo "$USER_NAME ALL=(root) NOPASSWD: $HELPER *" > "$TMP_SUDO"

sudo mkdir -p /usr/local/libexec
sudo cp "$TMP_HELPER" "$HELPER"
sudo chown root:wheel "$HELPER"
sudo chmod 755 "$HELPER"
sudo cp "$TMP_SUDO" "$SUDOERS"
sudo chown root:wheel "$SUDOERS"
sudo chmod 440 "$SUDOERS"
rm -f "$TMP_HELPER" "$TMP_SUDO"
if ! sudo visudo -cf "$SUDOERS" >/dev/null 2>&1; then
  sudo rm -f "$SUDOERS"; die "sudoers 驗證失敗，已移除"
fi
ok "免密碼權限已設定（使用者 $USER_NAME）"

# 7) 安裝到 /Applications
say "安裝到 /Applications…"
rm -rf "/Applications/FakeGPS.app"
cp -R "./build/FakeGPS.app" "/Applications/FakeGPS.app"
ok "安裝完成！可在 啟動台 / Applications 找到 FakeGPS"
echo
echo "首次開啟若被 Gatekeeper 擋：對 App 按右鍵 → 打開 → 再次打開。"
echo "解除安裝：執行 ./uninstall.sh"
