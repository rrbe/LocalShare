#!/usr/bin/env bash
# 编译 release 二进制 → 组装成 .app bundle → ad-hoc 签名（arm64 可执行的最低要求）。
# 产物在 dist/ 下，可直接 open 自测或拷给同事。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="LanFileShare"
APP_DISPLAY="局域网文件分享"
APP="$ROOT/dist/$APP_DISPLAY.app"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"

BIN_PATH="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$BINARY"
[ -f "$BIN_PATH" ] || { echo "构建产物未找到: $BIN_PATH"; exit 1; }

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BINARY"
cp "$ROOT/bundle/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "==> 完成: $APP"
echo "本机自测:  open \"$APP\""
