#!/bin/bash
# 一次性配置公证凭据：双击运行，按提示输入 Apple ID 和 App 专用密码即可。
# App 专用密码在 https://appleid.apple.com → 登录与安全 → App 专用密码 里生成。

pause() { echo ""; read -r -p "按回车键关闭窗口…" _; }
trap pause EXIT

echo "==================================================="
echo "   配置公证凭据（一次性）"
echo "==================================================="
echo ""

# 从钥匙串里的 Developer ID 证书自动探测 Team ID 作为默认值
DETECTED_TEAM=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 \
  | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/')

PROFILE="udid-notary"

read -r -p "Apple ID 邮箱: " APPLE_ID
if [ -z "$APPLE_ID" ]; then echo "❌ Apple ID 不能为空"; exit 1; fi

if [ -n "$DETECTED_TEAM" ]; then
  read -r -p "Team ID [直接回车用默认 $DETECTED_TEAM]: " TEAM_ID
  TEAM_ID="${TEAM_ID:-$DETECTED_TEAM}"
else
  read -r -p "Team ID: " TEAM_ID
fi
if [ -z "$TEAM_ID" ]; then echo "❌ Team ID 不能为空"; exit 1; fi

read -r -s -p "App 专用密码（输入时不显示，可直接粘贴）: " APP_PW
echo ""
if [ -z "$APP_PW" ]; then echo "❌ App 专用密码不能为空"; exit 1; fi

echo ""
echo "正在存入公证凭据（名称：$PROFILE）…"
echo ""
if xcrun notarytool store-credentials "$PROFILE" \
     --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW"; then
  echo ""
  echo "✅ 配置成功！接下来双击「打包.command」就能打包了。"
else
  echo ""
  echo "❌ 配置失败。常见原因："
  echo "   · 这个 Apple ID 不属于 Team $TEAM_ID（要和签名证书同一个团队）"
  echo "   · App 专用密码输错（注意是专用密码，不是 Apple ID 登录密码）"
fi
