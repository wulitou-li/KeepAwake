#!/bin/zsh
# KeepAwake 构建脚本：编译 -> 打包 -> 签名 -> 安装到 /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="$ROOT/KeepAwake.app"
BIN="$APP/Contents/MacOS/KeepAwake"

echo "==> 编译"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macosx13.0 -o "$BIN" main.swift

echo "==> 写入 Info.plist"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> 本地签名（adhoc）"
codesign --force --deep --sign - "$APP"

echo "==> 安装到 /Applications"
rm -rf /Applications/KeepAwake.app
cp -R "$APP" /Applications/KeepAwake.app
xattr -dr com.apple.quarantine /Applications/KeepAwake.app 2>/dev/null || true

echo "==> 完成"
echo "启动：open /Applications/KeepAwake.app"
