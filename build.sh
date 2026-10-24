#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
# 本机 CommandLineTools 的 PackageDescription 较旧；存在兼容层时自动使用，避免裸 swift build 失败。
if [ -x "$SCRIPT_DIR/.env-tools/swiftc-manifest" ]; then
    export SWIFT_EXEC_MANIFEST="$SCRIPT_DIR/.env-tools/swiftc-manifest"
fi
swift build -c release --product Yaosnap
APP="Build/Yaosnap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Yaosnap "$APP/Contents/MacOS/Yaosnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
