#!/usr/bin/env bash
set -euo pipefail
# 需要环境变量：DEV_ID_APP="Developer ID Application: NAME (TEAMID)"，NOTARY_PROFILE=公证 keychain profile 名
APP="UDIDRegisterMac.app"
BIN="UDIDRegisterApp"
DIST="dist"

swift build -c release --product "$BIN"

rm -rf "$DIST/$APP"; mkdir -p "$DIST/$APP/Contents/MacOS" "$DIST/$APP/Contents/Resources"
cp ".build/release/$BIN" "$DIST/$APP/Contents/MacOS/$BIN"

cat > "$DIST/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>UDID 注册助手</string>
<key>CFBundleIdentifier</key><string>com.yourco.UDIDRegisterMac</string>
<key>CFBundleExecutable</key><string>$BIN</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

codesign --force --options runtime --timestamp \
  --entitlements Resources/UDIDRegisterMac.entitlements \
  --sign "$DEV_ID_APP" "$DIST/$APP"

hdiutil create -volname "UDID 注册助手" -srcfolder "$DIST/$APP" -ov -format UDZO "$DIST/UDIDRegisterMac.dmg"

xcrun notarytool submit "$DIST/UDIDRegisterMac.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/UDIDRegisterMac.dmg"
echo "✅ 完成：$DIST/UDIDRegisterMac.dmg"
