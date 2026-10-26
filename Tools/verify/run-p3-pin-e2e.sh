#!/bin/bash
# 编译并运行 P3 贴图验收 harness。
# 直接复用生产源码 PinWindow / PinController 与 YaosnapCore，程序化驱动剪贴板贴图。
set -euo pipefail
cd "$(dirname "$0")/../.."

./build.sh

mkdir -p /tmp/yaosnap-verify/build /tmp/yaosnap-verify/evidence

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Yaosnap/Pin/PinWindow.swift \
    Sources/Yaosnap/Pin/PinController.swift \
    Sources/Yaosnap/Pin/PinToolbar.swift \
    Tools/verify/P3PinE2E.swift \
    "$PWD/.build/release/YaosnapCore.o" \
    -o /tmp/yaosnap-verify/build/p3pinharness

/tmp/yaosnap-verify/build/p3pinharness
