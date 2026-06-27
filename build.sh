#!/usr/bin/env bash
# 编译 release universal 二进制（arm64 + x86_64）→ 组装成 .app bundle → ad-hoc 签名。
# 产物在 dist/ 下，可直接 open 自测或拷给同事（Apple Silicon 与 Intel Mac 通吃）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="LocalShare"
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

echo "==> 内置 Sparkle.framework（随包走，不依赖任何包外 dylib）"
# Sparkle 是二进制 framework（非源码），SPM 把它解到 .build/artifacts 下的 xcframework；
# 取 macOS 切片（已含 arm64+x86_64）整体拷进 Contents/Frameworks。主二进制以 @rpath 引用它，
# 而 build.sh 为 LocalShare 链入的 rpath 是 @executable_path/../Frameworks → 正好落到这里。
FRAMEWORK_SRC="$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
[ -n "$FRAMEWORK_SRC" ] && [ -d "$FRAMEWORK_SRC" ] || { echo "未找到 Sparkle.framework（先跑过 swift build？）"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
# ditto 完整保留 framework 的 Versions 符号链接与权限（codesign 对结构敏感，勿用 cp）。
ditto "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> ad-hoc 签名（inside-out：先内置 framework，再整个 app）"
# 必须先签嵌套代码再签外层。--deep 递归签 framework 内的 XPCServices / Updater.app / Autoupdate /
# Sparkle dylib；ad-hoc 无特殊 requirement，--deep 在此可靠。随后签 app 主体并封包。
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"

echo "==> 校验依赖：禁止包外 dylib，仅允许已内置的 @rpath framework（放宽后的核心戒律）"
# 核心戒律：不依赖任何包外 dylib——运行时若去包外路径（/opt/homebrew 等）找库，换台没装的机器就缺库崩溃。这里逐条检查主二进制依赖：
# 系统库放行；@rpath 引用必须对应 Contents/Frameworks 里确实存在的 framework；其余（绝对路径
# 包外 dylib）一律判失败。
FAIL=0
while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
        /usr/lib/*|/System/Library/*) ;;  # 系统库，放行
        @rpath/*)
            fw="${dep#@rpath/}"; fw="${fw%%/*}"   # 取 framework 名，如 Sparkle.framework
            if [ -e "$APP/Contents/Frameworks/$fw" ]; then
                echo "  ok  内置依赖: $dep"
            else
                echo "  ✗   @rpath 依赖未随包: $dep（缺 Contents/Frameworks/$fw）"; FAIL=1
            fi
            ;;
        *) echo "  ✗   包外 dylib 依赖: $dep"; FAIL=1 ;;
    esac
# otool -L 对 universal 二进制会按架构各打一行头（顶格），依赖行则以制表符缩进——
# 只取缩进行即可跳过所有头行，sort -u 合并 arm64/x86_64 的重复项。
done < <(otool -L "$APP/Contents/MacOS/$BINARY" | grep '^[[:space:]]' | awk '{print $1}' | sort -u)
[ "$FAIL" -eq 0 ] || { echo "依赖校验失败：检测到包外 dylib，违反核心戒律（见 docs/ARCHITECTURE.md §0）"; exit 1; }

echo "==> 验证签名有效性"
codesign --verify --deep --strict "$APP"

echo "==> 完成: $APP"
lipo -info "$APP/Contents/MacOS/$BINARY"
echo "本机自测:  open \"$APP\""
