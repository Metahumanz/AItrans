#!/bin/bash
# 把 SwiftPM 产物打成 AITrans.app，并压缩为可分发的 zip。
#
# 用法：macos/Scripts/package-app.sh [版本号]
# 产物：macos/dist/AITrans.app、macos/dist/AITrans-<版本>-arm64.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.2.0}"
DIST="$MACOS_DIR/dist"
APP="$DIST/AITrans.app"

cd "$MACOS_DIR"

echo "==> 构建 Release"
# SwiftPM 自身的 sandbox 在部分 CI/受限环境下不可用，这里统一关闭。
swift build -c release --disable-sandbox

BIN="$(swift build -c release --disable-sandbox --show-bin-path)/AITransApp"
if [ ! -x "$BIN" ]; then
    echo "找不到可执行文件：$BIN" >&2
    exit 1
fi

echo "==> 组装 .app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AITrans"
chmod +x "$APP/Contents/MacOS/AITrans"

ICON="$MACOS_DIR/../assets/icon/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    echo "缺少图标：$ICON（先运行 python3 tools/gen_icon.py）" >&2
    exit 1
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>AITrans</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.metahumanz.aitrans</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AITrans</string>
    <key>CFBundleDisplayName</key>
    <string>AItrans</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名（Apple Silicon 可执行的最低要求，非 Developer ID）"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo "==> 压缩"
ARCH="$(uname -m)"
ZIP="$DIST/AITrans-${VERSION}-${ARCH}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "完成："
echo "  $APP"
echo "  $ZIP"
