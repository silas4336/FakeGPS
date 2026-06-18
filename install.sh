#!/usr/bin/env bash
#
# install.sh — One-shot installer for FakeGPS.
# 預檢環境 → 補齊相依（Homebrew / libimobiledevice / pymobiledevice3）→ 偵測路徑
# → 編譯 Universal App → 設定免密碼 tunnel 權限 → 安裝到 /Applications。
# 可重複執行（idempotent）。
#
set -euo pipefail
cd "$(dirname "$0")"

# ─── 輸出工具 ───
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$(printf '\033[1;36m?\033[0m %s ' "$1")" a; echo "${a:-}"; }

USER_NAME="$(whoami)"
STATE_DIR="$HOME/.fakegps"
HELPER="/usr/local/libexec/fakegps_tunnel.sh"
SUDOERS="/etc/sudoers.d/fakegps"

echo
bold "  📍 FakeGPS 安裝程式"
echo  "  ──────────────────────────────"
echo

# ─── 1. 預檢 ───
say "預檢系統環境…"
[ "$(uname)" = "Darwin" ] || die "FakeGPS 只能在 macOS 上執行。"

MACOS_VER="$(sw_vers -productVersion)"
if [ "${MACOS_VER%%.*}" -lt 14 ]; then
  warn "你的 macOS 是 $MACOS_VER，建議 14 以上（Liquid Glass 需要 26+，舊版會用毛玻璃 fallback）。"
fi

if ! command -v swiftc >/dev/null; then
  warn "找不到 swiftc（Xcode Command Line Tools）。"
  echo "  即將執行：xcode-select --install （會跳出安裝視窗，裝完再重跑此腳本）"
  [ "$(ask '現在安裝？[Y/n]')" != "n" ] && xcode-select --install || true
  die "請等 Command Line Tools 安裝完成後，再執行一次 ./install.sh"
fi
ok "Xcode Command Line Tools"

# Homebrew（缺就問是否裝）
if ! command -v brew >/dev/null; then
  warn "找不到 Homebrew。"
  if [ "$(ask '要自動安裝 Homebrew 嗎？[Y/n]')" != "n" ]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # 把 brew 加進這次 shell 的 PATH
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)"; done
  else
    die "需要 Homebrew，請先安裝：https://brew.sh"
  fi
fi
ok "Homebrew"

# ─── 2. 相依套件 ───
if ! { command -v idevice_id >/dev/null || [ -x /opt/homebrew/bin/idevice_id ] || [ -x /usr/local/bin/idevice_id ]; }; then
  say "安裝 libimobiledevice…"
  brew install libimobiledevice
fi
IDEVICE_ID="$( { command -v idevice_id || ls /opt/homebrew/bin/idevice_id /usr/local/bin/idevice_id; } 2>/dev/null | head -1)"
IDEVICEINFO="$( { command -v ideviceinfo || ls /opt/homebrew/bin/ideviceinfo /usr/local/bin/ideviceinfo; } 2>/dev/null | head -1)"
ok "libimobiledevice（$IDEVICE_ID）"

say "安裝 / 更新 pymobiledevice3…"
PYTHON="$(command -v python3)" || die "找不到 python3"
"$PYTHON" -m pip install --user -q -U pymobiledevice3 || die "pymobiledevice3 安裝失敗（試試 $PYTHON -m pip install -U pip）"
ok "pymobiledevice3（$("$PYTHON" -V 2>&1)）"

# ─── 3. 設定檔 ───
say "寫入設定…"
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/config" <<CFG
python=$PYTHON
idevice_id=$IDEVICE_ID
ideviceinfo=$IDEVICEINFO
helper=$HELPER
CFG
ok "設定寫入 $STATE_DIR/config"

# ─── 4. 編譯 ───
say "編譯 Universal App（arm64 + x86_64）…"
./build.sh ./build >/dev/null
ok "編譯完成"

# ─── 5. 免密碼 tunnel 權限 ───
say "設定免密碼 tunnel 權限（需要輸入一次系統密碼）…"
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
sudo cp "$TMP_HELPER" "$HELPER"; sudo chown root:wheel "$HELPER"; sudo chmod 755 "$HELPER"
sudo cp "$TMP_SUDO" "$SUDOERS"; sudo chown root:wheel "$SUDOERS"; sudo chmod 440 "$SUDOERS"
rm -f "$TMP_HELPER" "$TMP_SUDO"
sudo visudo -cf "$SUDOERS" >/dev/null 2>&1 || { sudo rm -f "$SUDOERS"; die "sudoers 驗證失敗，已移除"; }
ok "免密碼權限已設定（使用者 $USER_NAME）"

# ─── 6. 安裝 App ───
say "安裝到 /Applications…"
rm -rf "/Applications/FakeGPS.app"
cp -R "./build/FakeGPS.app" "/Applications/FakeGPS.app"
ok "已安裝 FakeGPS.app"

# ─── 完成 ───
echo
bold "🎉 安裝完成！"
echo
echo "下一步："
echo "  1. iPhone 開啟 開發者模式（設定 → 隱私權與安全性 → 開發者模式）"
echo "  2. 用 USB 接上 iPhone、解鎖、點「信任」"
echo "  3. 開啟 FakeGPS（首次若被擋：右鍵 → 打開 → 打開）"
echo
if [ "$(ask '現在就開啟 FakeGPS 嗎？[Y/n]')" != "n" ]; then
  open "/Applications/FakeGPS.app"
fi
echo "解除安裝：./uninstall.sh"
