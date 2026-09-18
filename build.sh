#!/usr/bin/env bash
# MacKZ 构建脚本 v2：把 Swift 源码编译成 MacKZ.app（只需 Command Line Tools，无需 Xcode 工程）
# 用法：
#   ./build.sh                   # 按当前机器架构构建
#   ARCH=universal ./build.sh    # 构建 arm64 + x86_64 通用二进制
#   MACOS_MIN=15.0 ./build.sh    # 指定最低系统版本（默认 14.0）
set -euo pipefail

BUILD_SCRIPT_VERSION="2"
APP_NAME="MacKZ"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

# 最低系统版本：允许外部用环境变量覆盖；用 :- 兜底，传空值也不会因 set -u 报「unbound variable」
MACOS_MIN="${MACOS_MIN:-14.0}"
ARCH="${ARCH:-$(uname -m)}"
SOURCES=("$ROOT"/Sources/MacKZ/*.swift)

echo "==> MacKZ build.sh v$BUILD_SCRIPT_VERSION（arch=$ARCH, min=macOS $MACOS_MIN）"

# ---------- 环境检查 ----------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误：MacKZ 只能在 macOS 上构建。" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误：未找到 swiftc，请先安装 Xcode Command Line Tools：" >&2
  echo "      xcode-select --install" >&2
  exit 1
fi
echo "    swiftc: $(swiftc --version 2>/dev/null | head -n 1)"

# 公共编译参数（frameworks 一次给全：IOKit=读铰链传感器，Metal/ScreenCaptureKit=实时重投影渲染）
COMMON_FLAGS=(
  -O
  -whole-module-optimization
  -framework Cocoa -framework IOKit -framework QuartzCore -framework CoreGraphics
  -framework Metal -framework ScreenCaptureKit -framework CoreVideo -framework CoreMedia
)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ---------- 编译 ----------
if [ "$ARCH" = "universal" ]; then
  for a in arm64 x86_64; do
    echo "==> 编译 $a"
    swiftc "${COMMON_FLAGS[@]}" -target "${a}-apple-macos${MACOS_MIN}" \
      -o "$BUILD_DIR/${APP_NAME}-${a}" "${SOURCES[@]}"
  done
  lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/${APP_NAME}-arm64" "$BUILD_DIR/${APP_NAME}-x86_64"
  rm -f "$BUILD_DIR/${APP_NAME}-arm64" "$BUILD_DIR/${APP_NAME}-x86_64"
else
  echo "==> 编译 $ARCH"
  swiftc "${COMMON_FLAGS[@]}" -target "${ARCH}-apple-macos${MACOS_MIN}" \
    -o "$APP/Contents/MacOS/$APP_NAME" "${SOURCES[@]}"
fi

# ---------- 打包 ----------
echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> 临时签名（本机自用足够；对外分发请换 Developer ID 证书）"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "    签名失败（不影响本机运行，可忽略）"

echo ""
echo "构建完成：$APP"
echo "运行试一下：open \"$APP\""
echo "安装到应用程序：cp -R \"$APP\" /Applications/"
