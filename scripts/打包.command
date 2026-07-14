#!/bin/bash
# 双击运行：自动签名 + 公证 + 生成 DMG。
# 首次使用前请先双击运行「配置公证凭据.command」。

pause() { echo ""; read -r -p "按回车键关闭窗口…" _; }
trap pause EXIT
set -uo pipefail

cd "$(dirname "$0")/.." || { echo "❌ 找不到项目目录"; exit 1; }

echo "==================================================="
echo "   打包发布（签名 + 公证 + DMG）"
echo "==================================================="
echo ""

# 自动探测 Developer ID Application 证书
DEV_ID_APP=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 \
  | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$DEV_ID_APP" ]; then
  echo "❌ 钥匙串里找不到 Developer ID Application 证书，无法签名。"
  exit 1
fi

NOTARY_PROFILE="udid-notary"

echo "签名证书：$DEV_ID_APP"
echo "公证凭据：$NOTARY_PROFILE"
echo ""
echo "开始打包（公证需联网、约 1~5 分钟，请耐心等待）…"
echo ""

export DEV_ID_APP NOTARY_PROFILE
if bash scripts/package.sh; then
  echo ""
  echo "✅ 完成！安装包在 dist/UDIDRegisterMac.dmg —— 这个就是发给同事的。"
  open dist 2>/dev/null || true
else
  echo ""
  echo "❌ 打包失败。可能原因："
  echo "   · 还没配置公证凭据 → 先双击「配置公证凭据.command」"
  echo "   · 网络问题 / 公证被拒 → 把上面的错误信息发给我"
fi
