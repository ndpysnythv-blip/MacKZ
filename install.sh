#!/usr/bin/env bash
# MacKZ 一键自动安装：编译 → 安装到 /Applications → 配置开机自启 → 启动。
# 用法：
#   ./install.sh              # 完整安装
#   ./install.sh --no-autostart   # 安装但不设置开机自启
#   ./install.sh --uninstall      # 卸载（程序 + 配置 + 自启项）
set -euo pipefail

APP_NAME="MacKZ"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$ROOT/build/$APP_NAME.app"
APP_DST="/Applications/$APP_NAME.app"
BUNDLE_ID="com.mackz.plugin"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SUPPORT="$HOME/Library/Application Support/$APP_NAME"

AUTOSTART=1
for arg in "$@"; do
  case "$arg" in
    --no-autostart) AUTOSTART=0 ;;
    --uninstall)    AUTOSTART=2 ;;
  esac
done

# ---------- 卸载 ----------
if [ "$AUTOSTART" = "2" ]; then
  echo "==> 卸载 MacKZ"
  launchctl unload "$AGENT" 2>/dev/null || true
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "$APP_DST" "$AGENT" "$SUPPORT"
  echo "卸载完成（程序、配置、自启项均已移除）"
  exit 0
fi

# ---------- 环境检查 ----------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：MacKZ 只能在 macOS 上安装。" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "未检测到 Swift 编译器，正在尝试触发 Command Line Tools 安装…"
  xcode-select --install 2>/dev/null || true
  echo "请在弹出的窗口中完成安装后，重新运行本脚本。" >&2
  exit 1
fi

# ---------- 编译 ----------
echo "==> 编译"
bash "$ROOT/build.sh"
[ -d "$APP_SRC" ] || { echo "编译产物缺失：$APP_SRC" >&2; exit 1; }

# ---------- 安装 ----------
echo "==> 关闭正在运行的旧实例"
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1
echo "==> 安装到 /Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DST" >/dev/null 2>&1 || true

mkdir -p "$SUPPORT"
[ -f "$SUPPORT/config.json" ] || cp "$ROOT/config.sample.json" "$SUPPORT/config.json"

# ---------- 开机自启 ----------
if [ "$AUTOSTART" = "1" ]; then
  echo "==> 配置开机自启"
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DST/Contents/MacOS/$APP_NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
PLIST
  launchctl unload "$AGENT" 2>/dev/null || true
  launchctl load "$AGENT"
fi

# ---------- 启动 ----------
echo "==> 启动 MacKZ"
open "$APP_DST"

cat <<'TIP'

安装完成 ✔
后续步骤：
  1) 菜单栏出现笔记本图标，点开可启停插件、标定角度、生成传感器探针报告；
  2) 首次想用真实画面做过渡：菜单 →「授权屏幕录制（Duo Continuity 画源）」；
  3) 配置文件：~/Library/Application Support/MacKZ/config.json（改后菜单「重载配置」即时生效）；
  4) 卸载：./install.sh --uninstall
TIP
