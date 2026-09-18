#!/usr/bin/env bash
# MacKZ 逐文件源码安装（低网络要求版）
#
# 为什么需要这个脚本：
#   部分网络环境下 github.com（git clone / release 下载）连不通，
#   但 raw.githubusercontent.com 可以正常访问。
#   本脚本只从 raw 域名逐个拉取源码文件再本地编译，因此在前述环境下依然能装。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-raw.sh | bash
set -euo pipefail

APP_NAME="MacKZ"
BUNDLE_ID="com.mackz.plugin"
APP_DST="/Applications/${APP_NAME}.app"
RAW_BASE="https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main"
WORK_ROOT="$(mktemp -d)"
WORK="${WORK_ROOT}/${APP_NAME}"

# 需要拉取的源码文件清单（新增源文件时记得同步这里）
FILES=(
  "build.sh"
  "Resources/Info.plist"
  "Sources/MacKZ/main.swift"
  "Sources/MacKZ/AppDelegate.swift"
  "Sources/MacKZ/Config.swift"
  "Sources/MacKZ/FoldShader.swift"
  "Sources/MacKZ/HingeAnimationEngine.swift"
  "Sources/MacKZ/LidAngleSensor.swift"
  "Sources/MacKZ/MetalFoldView.swift"
  "Sources/MacKZ/OverlayController.swift"
  "Sources/MacKZ/ScreenCaptureStream.swift"
  "Sources/MacKZ/SettingsWindow.swift"
  "Sources/MacKZ/StatusBarController.swift"
  "Sources/MacKZ/UpdateChecker.swift"
)

# 变量一律用 ${} 包裹：macOS 自带 bash 3.2 会把变量名后的中文字节吞进变量名
cleanup() { rm -rf "${WORK_ROOT}"; }
trap cleanup EXIT

echo "==> 检查运行环境"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：MacKZ 只能在 macOS 上安装。" >&2
  exit 1
fi

echo "==> 检查 Xcode 命令行工具"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "未检测到 swiftc，正在打开安装向导…"
  xcode-select --install 2>/dev/null || true
  echo "请在弹出的窗口中完成安装，然后重新运行本命令。" >&2
  exit 1
fi
echo "    swiftc: $(swiftc --version 2>/dev/null | head -n 1)"

echo "==> 逐文件下载源码（只访问 raw.githubusercontent.com）"
FAILED=0
for f in "${FILES[@]}"; do
  mkdir -p "${WORK}/$(dirname "${f}")"
  if curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 "${RAW_BASE}/${f}" -o "${WORK}/${f}"; then
    printf "    ✓ %s\n" "${f}"
  else
    printf "    ✗ %s（下载失败）\n" "${f}"
    FAILED=1
  fi
done

if [ "${FAILED}" = "1" ]; then
  echo "" >&2
  echo "错误：有文件下载失败。raw.githubusercontent.com 也可能被限速，可稍后重试。" >&2
  echo "      如仍不行，可设置代理后再跑（端口换成你自己的）：" >&2
  echo "        export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890" >&2
  exit 1
fi

echo "==> 编译（约需十几秒）"
cd "${WORK}"
bash ./build.sh

SRC="${WORK}/build/${APP_NAME}.app"
if [ ! -d "${SRC}" ]; then
  echo "错误：编译产物缺失，请把上面的报错反馈给作者。" >&2
  exit 1
fi

echo "==> 停掉旧实例并安装到 ${APP_DST}"
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1
rm -rf "${APP_DST}"
cp -R "${SRC}" "${APP_DST}"

# 本机编译产物本就不带隔离属性，这里再兜底清一次
xattr -cr "${APP_DST}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DST}" >/dev/null 2>&1 || true

# 清掉旧版本残留的「屏幕录制」授权记录（更新后签名变化会让 TCC 记录失配）
tccutil reset ScreenCapture "${BUNDLE_ID}" 2>/dev/null || true

echo "==> 配置开机自启"
AGENT="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
mkdir -p "$(dirname "${AGENT}")"
cat > "${AGENT}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${BUNDLE_ID}</string>
  <key>ProgramArguments</key>
  <array><string>${APP_DST}/Contents/MacOS/${APP_NAME}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
PLIST
launchctl unload "${AGENT}" 2>/dev/null || true
launchctl load "${AGENT}" || true

echo "==> 启动 MacKZ"
open "${APP_DST}"

cat <<'TIP'

安装完成
  1) 菜单栏出现 KZ 图标，点「设置…」可调所有参数；
  2) 没有铰链传感器的机型（如 MacBook Air 2020）用「手动预览」滑块体验动画；
  3) 更新：菜单栏 →「检查更新…」，或重新执行本命令；
  4) 卸载：rm -rf /Applications/MacKZ.app 和 ~/Library/LaunchAgents/com.mackz.plugin.plist
TIP
