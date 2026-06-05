#!/usr/bin/env bash
# 编译 release universal 二进制（arm64 + x86_64）→ 组装成 .app bundle → ad-hoc 签名。
# 产物在 dist/ 下，可直接 open 自测或拷给同事（Apple Silicon 与 Intel Mac 通吃）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="LanFileShare"
APP_DISPLAY="LocalShare"
APP="$ROOT/dist/$APP_DISPLAY.app"
# 两个架构都编，cp 时合成 fat binary。纯 Swift（含 Swifter 源码）可在任一机型交叉编译。
ARCHS=(--arch arm64 --arch x86_64)

echo "==> swift build -c release (arm64 + x86_64)"
swift build -c release --package-path "$ROOT" "${ARCHS[@]}"

BIN_PATH="$(swift build -c release --package-path "$ROOT" "${ARCHS[@]}" --show-bin-path)/$BINARY"
[ -f "$BIN_PATH" ] || { echo "构建产物未找到: $BIN_PATH"; exit 1; }

echo "==> 校验 universal 切片"
lipo -info "$BIN_PATH"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BINARY"
cp "$ROOT/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/bundle/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "==> 完成: $APP"
lipo -info "$APP/Contents/MacOS/$BINARY"
echo "本机自测:  open \"$APP\""
