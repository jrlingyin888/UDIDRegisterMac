#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 需要环境变量：DEV_ID_APP="Developer ID Application: NAME (TEAMID)"，NOTARY_PROFILE=公证 keychain profile 名
APP="UDIDRegisterMac.app"
BIN="UDIDRegisterApp"
DIST="dist"

# bundle-id 单一来源：从 AppIdentifiers.swift 抽取，保证与 Keychain service 一致
BUNDLE_ID=$(grep -Eo 'bundleID[[:space:]]*=[[:space:]]*"[^"]+"' Sources/UDIDRegisterKit/AppIdentifiers.swift | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$BUNDLE_ID" ] || { echo "❌ 无法从 AppIdentifiers.swift 解析 bundleID"; exit 1; }
echo "Bundle ID: $BUNDLE_ID"

[ -f Resources/AppIcon.icns ] || { echo "❌ 缺少 Resources/AppIcon.icns，请先运行 swift scripts/make-icon.swift"; exit 1; }

swift build -c release --product "$BIN"

rm -rf "$DIST/$APP"; mkdir -p "$DIST/$APP/Contents/MacOS" "$DIST/$APP/Contents/Resources"
cp ".build/release/$BIN" "$DIST/$APP/Contents/MacOS/$BIN"
cp Resources/AppIcon.icns "$DIST/$APP/Contents/Resources/AppIcon.icns"

cp Resources/Info.plist "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BIN" "$DIST/$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp \
  --entitlements Resources/UDIDRegisterMac.entitlements \
  --sign "$DEV_ID_APP" "$DIST/$APP"

hdiutil create -volname "UDID 注册助手" -srcfolder "$DIST/$APP" -ov -format UDZO "$DIST/UDIDRegisterMac.dmg"

xcrun notarytool submit "$DIST/UDIDRegisterMac.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/$APP"
xcrun stapler staple "$DIST/UDIDRegisterMac.dmg"
echo "✅ 完成：$DIST/UDIDRegisterMac.dmg"
