#!/bin/bash
# 打包成可以双击运行的 MarketPane.app（菜单栏 + 桌面面板，不需要 Xcode 工程）
# 用法：Scripts/build-app.sh            → 生成 build/MarketPane.app
#       Scripts/build-app.sh --install  → 同时安装到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MarketPane
BIN="$(swift build -c release --product MarketPane --show-bin-path)/MarketPane"

APP="build/MarketPane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MarketPane"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 图标源码见 Scripts/AppIcon.swift、Scripts/make-icon.sh
codesign --force --deep --sign - "$APP"   # ad-hoc 签名，本机运行足够
echo "已生成 $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/MarketPane.app
    cp -R "$APP" ~/Applications/
    echo "已安装到 ~/Applications/MarketPane.app"
fi
