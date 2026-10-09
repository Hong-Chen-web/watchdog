#!/bin/zsh
# Watchdog.app 打包:release 二进制 + sidecar + 字体资源 + 图标 + ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

APP=dist/Watchdog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 主程序 + sidecar 后端(PyInstaller 产物,若存在)
cp .build/release/Watchdog "$APP/Contents/MacOS/Watchdog"
# frozen 以 server/dist 为准(刚构建的),bin/ 只作兜底
SIDE=../../server/dist/watchdog-server
[ -f "$SIDE" ] || SIDE=bin/watchdog-server
cp "$SIDE" "$APP/Contents/MacOS/watchdog-server"

# 资源:Phosphor 字体 + 图标
cp Assets/Phosphor.ttf "$APP/Contents/Resources/Phosphor.ttf"
[ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>看门狗 Watchdog</string>
    <key>CFBundleDisplayName</key><string>看门狗</string>
    <key>CFBundleIdentifier</key><string>com.chenhong.watchdog</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Watchdog</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "bundled: $APP"
du -sh "$APP"

# dmg(分发产物;旧文件必须先删,hdiutil 无 -ov 时遇已存在文件会失败)
rm -f dist/Watchdog_1.0.0_aarch64.dmg
if ! hdiutil create -format UDZO -srcfolder "$APP" -volname "Watchdog" dist/Watchdog_1.0.0_aarch64.dmg >/dev/null 2>&1; then
    echo "WARN: dmg create failed (app 可能正在运行),跳过"
fi
echo "dmg: dist/Watchdog_1.0.0_aarch64.dmg"
du -sh dist/Watchdog_1.0.0_aarch64.dmg 2>/dev/null
