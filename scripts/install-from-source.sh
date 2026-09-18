#!/usr/bin/env bash
# MacKZ 源码一键安装（最推荐）：
#   本机拉源码 + 本机编译 + 装到 /Applications。
#   全程不经过“下载”，因此产物不带 com.apple.quarantine 隔离属性，
#   装完双击即可打开，不需要在系统设置里点“仍要打开”。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-from-source.sh | bash
set -euo pipefail

REPO_HTTPS="https://github.com/ndpysnythv-blip/MacKZ.git"
REPO_SSH="git@github.com:ndpysnythv-blip/MacKZ.git"
APP_NAME="MacKZ"
BUNDLE_ID="com.mackz.plugin"
APP_DST="/Applications/${APP_NAME}.app"
WORK_ROOT="$(mktemp -d)"
WORK="${WORK_ROOT}/${APP_NAME}"
# 用户之前手动 clone 过的仓库，优先复用（省一次下载）
LOCAL_SRC="${HOME}/${APP_NAME}"

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

echo "==> 获取源码"
SRC_DIR=""
GIT_LOG="${WORK_ROOT}/git-error.log"

# 低速保护：连续 20 秒低于 1KB/s 就中断，避免卡在“假死”状态
GIT_OPTS=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20)

try_pull_local() {
  [ -d "${LOCAL_SRC}/.git" ] || return 1
  echo "    发现本地源码 ${LOCAL_SRC}，尝试更新…"
  if git -C "${LOCAL_SRC}" "${GIT_OPTS[@]}" pull --ff-only >"${GIT_LOG}" 2>&1; then
    echo "    已更新到最新版本"
    SRC_DIR="${LOCAL_SRC}"
    return 0
  fi
  echo "    更新失败，稍后改用重新下载"
  return 1
}

try_clone() {
  local url="$1"
  rm -rf "${WORK}"
  git "${GIT_OPTS[@]}" clone --depth 1 "${url}" "${WORK}" >"${GIT_LOG}" 2>&1
}

try_pull_local || true

if [ -z "${SRC_DIR}" ]; then
  echo "    正在下载源码…"
  if try_clone "${REPO_HTTPS}"; then
    SRC_DIR="${WORK}"
  elif try_clone "${REPO_SSH}"; then          # 配过 SSH key 的话走这条路
    SRC_DIR="${WORK}"
  else
    echo "" >&2
    echo "错误：无法获取源码（git 报错如下）" >&2
    echo "----------------------------------------" >&2
    cat "${GIT_LOG}" >&2
    echo "----------------------------------------" >&2
    echo "" >&2
    echo "常见原因与解决办法：" >&2
    echo "  1) 网络访问 GitHub 不通 —— 设置代理后重试（端口换成你自己的）：" >&2
    echo "       export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890" >&2
    echo "  2) 已有本地仓库但更新失败 —— 可先删掉再重试：" >&2
    echo "       rm -rf ${LOCAL_SRC}" >&2
    echo "  3) 怀疑 DNS 被污染 —— 换网络或开启系统全局代理后重试。" >&2
    exit 1
  fi
fi

echo "==> 编译（约需十几秒）"
cd "${SRC_DIR}"
bash ./build.sh

SRC="${SRC_DIR}/build/${APP_NAME}.app"
if [ ! -d "${SRC}" ]; then
  echo "错误：编译产物缺失，请把上面的报错反馈给作者。" >&2
  exit 1
fi

echo "==> 停掉旧实例并安装到 ${APP_DST}"
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1
rm -rf "${APP_DST}"
cp -R "${SRC}" "${APP_DST}"

# 本机编译产物本来就没有隔离属性，这里再兜底清一次（防止从别处拷贝时带进来）
xattr -cr "${APP_DST}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_DST}" >/dev/null 2>&1 || true

# 清掉上一个版本残留的「屏幕录制」授权记录：
# 本地临时签名每次构建都会变，TCC 记录会与新版本失配，
# 表现为「系统设置里已勾选，程序却一直显示未授权且无法再授权」。
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
  1) 菜单栏出现笔记本图标，点「设置…」可调所有参数；
  2) 首次启动会自动申请「屏幕录制」权限，授权后程序会自动重启生效；
  3) 更新：菜单栏 →「检查更新…」；
  4) 卸载：rm -rf /Applications/MacKZ.app 和 ~/Library/LaunchAgents/com.mackz.plugin.plist
TIP
