#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product Yaosnap
APP="Build/Yaosnap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Yaosnap "$APP/Contents/MacOS/Yaosnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
