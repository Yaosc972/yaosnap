#!/bin/bash
# 编译并运行 P1 验收 harness。
# 直接复用生产源码（SnipController / OverlayView / SnipOverlayWindow）与 YaosnapCore，
# 程序化驱动 start / 拖拽 / 按键 / 复制 / 保存，截图写到 /tmp/yaosnap-verify/evidence。
set -euo pipefail
cd "$(dirname "$0")/../.."

./build.sh

mkdir -p /tmp/yaosnap-verify/build /tmp/yaosnap-verify/evidence

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Yaosnap/Snip/SnipController.swift \
    Sources/Yaosnap/Snip/OverlayView.swift \
    Sources/Yaosnap/Snip/SnipOverlayWindow.swift \
    Sources/Yaosnap/Snip/ActionBarView.swift \
    Tools/verify/P1E2E.swift \
    "$PWD/.build/release/YaosnapCore.o" \
    -o /tmp/yaosnap-verify/build/p1harness

/tmp/yaosnap-verify/build/p1harness
