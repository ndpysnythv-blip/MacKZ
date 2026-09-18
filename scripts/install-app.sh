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

echo "==> 清除系统隔离属性"
# 关键步骤：只要还残留 com.apple.quarantine，未公证的应用就会被 Gatekeeper 拦住，
# 且“系统设置 → 隐私与安全性”里可能连“仍要打开”都不出现。
# 用 -cr 清掉全部扩展属性（不只是 quarantine），比 -dr 更彻底。
if ! xattr -cr "${APP_DST}" 2>/dev/null; then
  echo "    普通权限清除失败，稍后需要手动执行一次 sudo 命令（见文末）"
fi

echo "==> 重新做本地签名（避免解压后签名结构失效导致提示“已损坏”）"
codesign --force --deep --sign - "${APP_DST}" >/dev/null 2>&1 || true

# 校验隔离属性是否真的清干净了
NEED_SUDO=0
if xattr -p com.apple.quarantine "${APP_DST}" >/dev/null 2>&1; then
  NEED_SUDO=1
fi

echo "==> 启动 MacKZ"
open "${APP_DST}" 2>/dev/null || NEED_SUDO=1

if [ "${NEED_SUDO}" = "1" ]; then
  cat <<'TIP'

【还差一步】系统仍带着隔离属性，请手动执行（会要求输入开机密码）：

  sudo xattr -cr /Applications/MacKZ.app
  sudo codesign --force --deep --sign - /Applications/MacKZ.app
  open /Applications/MacKZ.app

如果执行后依旧打不开，改用源码安装方式（本机编译不带隔离属性，最稳）：

  curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-from-source.sh | bash
TIP
  exit 0
fi

cat <<'TIP'

安装完成
  1) 菜单栏出现笔记本图标，点「设置…」可调所有参数；
  2) 首次启动会自动申请「屏幕录制」权限，授权后程序自动重启生效；
  3) 若仍被系统拦截，执行：sudo xattr -cr /Applications/MacKZ.app
  4) 卸载：rm -rf /Applications/MacKZ.app
TIP
