#!/usr/bin/env bash
# MacKZ 低网络要求安装脚本
#
# 为什么这样写：
#   部分网络环境下 github.com（git clone / release 下载）连不通，或 raw.githubusercontent.com
#   会在「连上之后」停止给数据（假死）。旧版脚本只用 --connect-timeout，它只覆盖「建立连接」阶段，
#   连上后没数据 curl 会无限等待，表现为「卡住不动」，而且 -s 不打印任何东西，无法判断。
#
#   本脚本的策略：
#     1) 优先一次性下载源码 tar 包（只有 1 条连接，比逐个文件 14 条连接稳得多）；
#     2) 每次请求都带 --max-time 与 --speed-limit/--speed-time：假死连接会在 8 秒内被判定超时并重试；
#     3) 内置多个镜像（官方 / jsDelivr / 公共代理），任一可用即可；
#     4) tar 包全部失败才回退到逐文件下载。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-raw.sh | bash

set -euo pipefail

APP_NAME="MacKZ"
OWNER="ndpysnythv-blip"
REPO="MacKZ"
BRANCH="main"
BUNDLE_ID="com.mackz.plugin"
APP_DST="/Applications/${APP_NAME}.app"

WORK_ROOT="$(mktemp -d)"
SOURCE_DIR="${WORK_ROOT}/${APP_NAME}"

# ---------- 公共 curl 参数 ----------
# --max-time          单次请求最长耗时，防止「连上但没数据」的假死
# --speed-limit/-time 8 秒内平均速度低于 1KB/s 即判定为卡死并中断（触发 --retry）
# --retry             中断/5xx 自动重试
CURL_OPTS=(
  -fsSL
  --connect-timeout 10
  --max-time 60
  --speed-limit 1024
  --speed-time 8
  --retry 3
  --retry-delay 2
)
# 老版本 curl 不认识 --retry-all-errors，支持才加，避免直接报错
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
  CURL_OPTS+=(--retry-all-errors)
fi

# ---------- 镜像列表 ----------
# 源码 tar 包（单连接）
TARBALL_URLS=(
  "https://codeload.github.com/${OWNER}/${REPO}/tar.gz/refs/heads/${BRANCH}"
  "https://github.com/${OWNER}/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  "https://ghproxy.net/https://github.com/${OWNER}/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  "https://gh-proxy.com/https://github.com/${OWNER}/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
)
# 逐文件下载的基地址（回退方案用）
RAW_BASES=(
  "https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}"
  "https://cdn.jsdelivr.net/gh/${OWNER}/${REPO}@${BRANCH}"
  "https://ghproxy.net/https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}"
  "https://raw.gitmirror.com/${OWNER}/${REPO}/${BRANCH}"
)
# 逐文件清单（新增源文件时记得同步这里）
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

# 下载单个 URL 到文件；返回 0 表示成功且内容有效（非空、不是 HTML 错误页）
fetch() {
  local url="$1" out="$2" max="${3:-60}"
  rm -f "${out}"
  if ! curl "${CURL_OPTS[@]}" --max-time "${max}" "${url}" -o "${out}"; then
    return 1
  fi
  [ -s "${out}" ] || return 1
  # 代理/网关经常用 200 + HTML 错误页糊弄，这里挡掉
  if head -c 1 "${out}" 2>/dev/null | grep -q '<'; then
    return 1
  fi
  return 0
}

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

# ---------- 第一步：整包下载 ----------
echo "==> 下载源码包（整包一次下载，最快的路径）"
GOT_TARBALL=0
for i in "${!TARBALL_URLS[@]}"; do
  url="${TARBALL_URLS[$i]}"
  printf "    [%d/%d] %s\n" "$((i + 1))" "${#TARBALL_URLS[@]}" "$(echo "${url}" | sed 's#^https://##' | cut -c1-60)"
  if fetch "${url}" "${WORK_ROOT}/src.tar.gz" 180; then
    if tar -xzf "${WORK_ROOT}/src.tar.gz" -C "${WORK_ROOT}" 2>/dev/null; then
      GOT_TARBALL=1
      echo "    ✓ 源码包下载并解压成功"
      break
    fi
    echo "    ✗ 压缩包损坏，换下一个镜像"
  else
    echo "    ✗ 连接超时或失败，换下一个镜像"
  fi
done

# 解压后的目录名形如 MacKZ-main
if [ "${GOT_TARBALL}" = "1" ]; then
  EXTRACTED="$(find "${WORK_ROOT}" -maxdepth 1 -type d -name "${REPO}-*" | head -n 1)"
  if [ -n "${EXTRACTED}" ] && [ -f "${EXTRACTED}/build.sh" ]; then
    mv "${EXTRACTED}" "${SOURCE_DIR}"
  else
    echo "    ✗ 解压结果不完整，改用逐文件下载"
    GOT_TARBALL=0
  fi
fi

# ---------- 第二步：逐文件回退 ----------
if [ "${GOT_TARBALL}" != "1" ]; then
  echo "==> 整包不可用，改为逐文件下载（每个文件自动尝试多个镜像）"
  FAILED_FILES=()
  for f in "${FILES[@]}"; do
    mkdir -p "${SOURCE_DIR}/$(dirname "${f}")"
    ok=0
    for base in "${RAW_BASES[@]}"; do
      if fetch "${base}/${f}" "${SOURCE_DIR}/${f}" 60; then
        printf "    ✓ %s\n" "${f}"
        ok=1
        break
      fi
    done
    if [ "${ok}" != "1" ]; then
      printf "    ✗ %s（所有镜像均失败）\n" "${f}"
      FAILED_FILES+=("${f}")
    fi
  done
  if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
    echo "" >&2
    echo "错误：以下文件所有镜像都没下载成功：" >&2
    printf '      - %s\n' "${FAILED_FILES[@]}" >&2
    echo "      说明当前网络对 GitHub 及其公共镜像都不可用。可挂代理后重试：" >&2
    echo "        export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890" >&2
    exit 1
  fi
fi

if [ ! -f "${SOURCE_DIR}/build.sh" ] || [ ! -d "${SOURCE_DIR}/Sources/MacKZ" ]; then
  echo "错误：源码目录结构不完整，请把上面的输出反馈给作者。" >&2
  exit 1
fi
echo "    源文件数：$(find "${SOURCE_DIR}/Sources/MacKZ" -name '*.swift' | wc -l | tr -d ' ')"

# ---------- 第三步：编译 ----------
echo "==> 编译（首次约需 10~60 秒）"
cd "${SOURCE_DIR}"
if ! bash ./build.sh; then
  echo "" >&2
  echo "错误：编译失败。请把 build.sh 的报错内容完整复制反馈。" >&2
  exit 1
fi

SRC="${SOURCE_DIR}/build/${APP_NAME}.app"
if [ ! -d "${SRC}" ]; then
  echo "错误：编译产物缺失，请把上面的报错反馈给作者。" >&2
  exit 1
fi

# ---------- 第四步：安装 ----------
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
AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
mkdir -p "$(dirname "${AGENT}")"
# 用 printf 而不是 heredoc：脚本本身是通过管道喂给 bash 的，heredoc 在这种执行方式下容易出意外
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  "  <key>Label</key><string>${BUNDLE_ID}</string>" \
  '  <key>ProgramArguments</key>' \
  "  <array><string>${APP_DST}/Contents/MacOS/${APP_NAME}</string></array>" \
  '  <key>RunAtLoad</key><true/>' \
  '  <key>KeepAlive</key><false/>' \
  '</dict></plist>' > "${AGENT}"
launchctl unload "${AGENT}" 2>/dev/null || true
launchctl load "${AGENT}" || true

echo "==> 启动 MacKZ"
open "${APP_DST}"

cat <<'TIP'

安装完成
  1) 菜单栏出现 KZ 图标，点「设置…」可调所有参数；
  2) 折叠动画需要「屏幕录制」权限：菜单栏 →「授权屏幕录制」，授权后按提示重启生效；
  3) 没有铰链角度传感器的机型，用设置面板的「手动预览」滑块体验动画；
  4) 更新：菜单栏 →「检查更新…」，或重新执行本命令；
  5) 卸载：rm -rf /Applications/MacKZ.app ~/Library/LaunchAgents/com.mackz.plugin.plist
TIP
