#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
# 本机 CommandLineTools 的 PackageDescription 较旧；存在兼容层时自动使用，避免裸 swift build 失败。
if [ -x "$SCRIPT_DIR/.env-tools/swiftc-manifest" ]; then
    export SWIFT_EXEC_MANIFEST="$SCRIPT_DIR/.env-tools/swiftc-manifest"
fi
swift build -c release --product Yaosnap
swift build -c release --product snip
APP="Build/Yaosnap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Yaosnap "$APP/Contents/MacOS/Yaosnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/StatusBarIcon.png Resources/StatusBarIcon@2x.png \
    Resources/MenuItemIcon.png Resources/MenuItemIcon@2x.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 有本地证书就用它签名：ad-hoc 的 CDHash 会随代码变化，辅助功能授权每次重建都要重勾。
SIGN_ID="Yaosnap Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    codesign --force --deep --sign - "$APP"
    echo "提示：当前为 ad-hoc 签名，改代码重建后辅助功能授权可能失效。运行一次 Tools/setup-signing.sh 可固定签名。"
fi
echo "Built $APP"
CLI="$SCRIPT_DIR/.build/release/snip"
echo "Built CLI $CLI"
echo "加入 PATH（写入你的 shell 配置）：export PATH=\"$SCRIPT_DIR/.build/release:\$PATH\""
