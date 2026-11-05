#!/bin/bash
# 把 SwiftPM 产物打成 AITrans.app，压缩为 zip，并制作 dmg。
#
# 用法：macos/Scripts/package-app.sh [版本号]
# 产物：macos/dist/AITrans.app、AITrans-<版本>-<arch>.zip、AITrans-<版本>-<arch>.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.3.5}"
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
    <string>AITrans</string>
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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>localhost</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>127.0.0.1</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>127.0.0.0/8</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>::1</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>10.0.0.0/8</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>172.16.0.0/12</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>192.168.0.0/16</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>169.254.0.0/16</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>fc00::/7</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
            <key>fe80::/10</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
        </dict>
    </dict>
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

# dmg 里放一个 /Applications 软链，用户拖进去就是安装。
echo "==> 制作 dmg"
DMG="$DIST/AITrans-${VERSION}-${ARCH}.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/AITrans.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "AITrans" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "完成："
echo "  $APP"
echo "  $ZIP"
echo "  $DMG"
