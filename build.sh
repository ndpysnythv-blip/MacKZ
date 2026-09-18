#!/usr/bin/env bash
# MacKZ 一键构建脚本：把 Swift 源码编译成 MacKZ.app（无需 Xcode 工程，只要 Command Line Tools）
# 用法：
#   ./build.sh              # 按当前机器架构构建
#   ARCH=universal ./build.sh   # 构建 arm64 + x86_64 通用二进制
set -euo pipefail

APP_NAME="MacKZ"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_MIN="14.0"

ARCH="${ARCH:-$(uname -m)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译（arch=$ARCH, min=macOS $MACOS_MIN）"
if [ "$ARCH" = "universal" ]; then
  for a in arm64 x86_64; do
    swiftc -O -whole-module-optimization \
      -target "${a}-apple-macos${MACOS_MIN}" \
      -framework Cocoa -framework IOKit -framework QuartzCore -framework CoreGraphics \
      -framework Metal -framework ScreenCaptureKit -framework CoreVideo -framework CoreMedia \
      -o "$BUILD_DIR/${APP_NAME}-${a}" \
      "$ROOT"/Sources/MacKZ/*.swift
  done
  lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/${APP_NAME}-arm64" "$BUILD_DIR/${APP_NAME}-x86_64"
  rm -f "$BUILD_DIR/${APP_NAME}-arm64" "$BUILD_DIR/${APP_NAME}-x86_64"
else
  swiftc -O -whole-module-optimization \
    -target "${ARCH}-apple-macos${MACOS_MIN}" \
    -framework Cocoa -framework IOKit -framework QuartzCore -framework CoreGraphics \
    -framework Metal -framework ScreenCaptureKit -framework CoreVideo -framework CoreMedia \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    "$ROOT"/Sources/MacKZ/*.swift
fi

echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> 临时签名（本机自用足够；对外分发请换 Developer ID 证书）"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "    签名失败（不影响本机运行，可忽略）"

echo ""
echo "构建完成：$APP"
echo "运行试一下：open \"$APP\""
echo "安装到应用程序：cp -R \"$APP\" /Applications/"
