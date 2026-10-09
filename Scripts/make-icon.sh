#!/bin/bash
# 重新生成 Resources/AppIcon.icns（画法在 Scripts/AppIcon.swift）。改完再跑 Scripts/build-app.sh --install
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
swift Scripts/AppIcon.swift "$TMP/icon_1024.png"
# 只放 128 以上：放了 16/32 的小图，macOS 27 会把小尺寸套进灰框、把红绿线染成蓝色；不放就由系统自己缩，显示正常
for s in 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o Resources/AppIcon.icns "$SET"
echo "已生成 Resources/AppIcon.icns"
