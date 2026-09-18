#!/usr/bin/env bash
# MacKZ 在线一键安装：从 GitHub Release 拉取最新版 MacKZ.app 并安装到 /Applications。
#
# 用法（不用先 clone 仓库，终端里直接跑）：
#   curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-app.sh | bash
#
# 为什么要用这个脚本而不是浏览器下载：
#   浏览器下载的文件会被系统打上 com.apple.quarantine（隔离）扩展属性，
#   未经过 Apple 公证的 App 会被 Gatekeeper 拦下（“无法验证开发者，无法打开”）。
#   而 curl 下载的文件不带该属性，装完即可直接双击打开。
set -euo pipefail

REPO="ndpysnythv-blip/MacKZ"
APP_NAME="MacKZ"
APP_DST="/Applications/${APP_NAME}.app"
WORK="$(mktemp -d)"

# 变量一律用 ${} 包裹：macOS 自带 bash 3.2 会把变量名后的中文字节吞进变量名
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

echo "==> 检查运行环境"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：MacKZ 只能在 macOS 上安装。" >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "提示：当前架构是 $(uname -m)，而 MacKZ 只提供 Apple Silicon 版本，可能无法运行。"
fi

echo "==> 从 GitHub 下载最新版本"
URL="https://github.com/${REPO}/releases/latest/download/${APP_NAME}.zip"
curl -fL --progress-bar "${URL}" -o "${WORK}/${APP_NAME}.zip"

echo "==> 解压"
ditto -x -k "${WORK}/${APP_NAME}.zip" "${WORK}"
if [ ! -d "${WORK}/${APP_NAME}.app" ]; then
  echo "错误：压缩包里没有找到 ${APP_NAME}.app" >&2
  exit 1
fi

echo "==> 安装到 ${APP_DST}"
if pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
  echo "    检测到 MacKZ 正在运行，先退出旧实例"
  pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
  sleep 1
fi
rm -rf "${APP_DST}"
cp -R "${WORK}/${APP_NAME}.app" "${APP_DST}"

# 双保险：去掉隔离属性 + 本地临时签名，确保双击即可打开
xattr -dr com.apple.quarantine "${APP_DST}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DST}" >/dev/null 2>&1 || true

echo "==> 启动 MacKZ"
open "${APP_DST}"

cat <<'TIP'

安装完成
  1) 菜单栏出现笔记本图标，点「设置…」可调所有参数；
  2) 首次启动会自动申请「屏幕录制」权限，授权后程序自动重启生效；
  3) 若仍被系统拦截，执行：xattr -dr com.apple.quarantine /Applications/MacKZ.app
  4) 卸载：rm -rf /Applications/MacKZ.app
TIP
