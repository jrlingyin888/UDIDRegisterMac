#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 需要环境变量：DEV_ID_APP="Developer ID Application: NAME (TEAMID)"，NOTARY_PROFILE=公证 keychain profile 名
APP="ReSignMac.app"
BIN="ReSignApp"
DIST="dist"

# bundle-id 单一来源：从 ReSignAppIdentifiers.swift 抽取，保证与 Keychain service 一致
BUNDLE_ID=$(grep -Eo 'bundleID[[:space:]]*=[[:space:]]*"[^"]+"' Sources/ReSignAppCore/ReSignAppIdentifiers.swift | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$BUNDLE_ID" ] || { echo "❌ 无法从 ReSignAppIdentifiers.swift 解析 bundleID"; exit 1; }
echo "Bundle ID: $BUNDLE_ID"

[ -f Resources/ReSignAppIcon.icns ] || { echo "❌ 缺少 Resources/ReSignAppIcon.icns，请先运行 swift scripts/make-icon.swift resign"; exit 1; }

swift build -c release --product "$BIN"

rm -rf "$DIST/$APP"; mkdir -p "$DIST/$APP/Contents/MacOS" "$DIST/$APP/Contents/Resources"
cp ".build/release/$BIN" "$DIST/$APP/Contents/MacOS/$BIN"
cp Resources/ReSignAppIcon.icns "$DIST/$APP/Contents/Resources/ReSignAppIcon.icns"

cp Resources/ReSignApp-Info.plist "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BIN" "$DIST/$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp \
  --entitlements Resources/ReSignApp.entitlements \
  --sign "$DEV_ID_APP" "$DIST/$APP"

# ---- 生成带「拖入 应用程序」布局的 DMG ----
VOL="重签助手"
STAGE="$DIST/dmg-stage-resign"
RW="$DIST/rw-resign.dmg"
FINAL="$DIST/ReSignMac.dmg"

hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
rm -rf "$STAGE" "$RW" "$FINAL"
mkdir -p "$STAGE"
cp -R "$DIST/$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
DEV=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -Eo '^/dev/disk[0-9]+' | head -1)

osascript <<OSA || echo "（提示：窗口布局未设置——在弹窗里允许「控制 Finder」后重跑；DMG 仍可正常拖拽安装）"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 720, 470}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 96
    set position of item "$APP" of container window to {150, 175}
    set position of item "Applications" of container window to {380, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"

# ---- 公证 + staple（需 NOTARY_PROFILE）----
xcrun notarytool submit "$FINAL" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$FINAL"
echo "✅ 完成：$FINAL"
