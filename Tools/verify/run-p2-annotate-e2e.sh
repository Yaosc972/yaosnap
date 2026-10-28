#!/bin/bash
# 编译并运行 P2 标注验收 harness（第一批：矩形垂直切片）。
# 直接复用生产源码与 YaosnapCore，程序化驱动画标注 / 复制 / 状态机行为。
set -euo pipefail
cd "$(dirname "$0")/../.."

./build.sh

mkdir -p /tmp/yaosnap-verify/build /tmp/yaosnap-verify/evidence

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Yaosnap/Snip/SnipController.swift \
    Sources/Yaosnap/Snip/OverlayView.swift \
    Sources/Yaosnap/Snip/SnipOverlayWindow.swift \
    Sources/Yaosnap/Snip/TranslationResultWindow.swift \
    Sources/Yaosnap/Annotate/AnnotateToolbar.swift \
    Sources/Yaosnap/Annotate/AnnotationCanvas.swift \
    Sources/Yaosnap/Annotate/ToolStyleStore.swift \
    Tools/verify/P2AnnotateE2E.swift \
    "$PWD/.build/release/YaosnapCore.o" \
    -o /tmp/yaosnap-verify/build/p2annotateharness

/tmp/yaosnap-verify/build/p2annotateharness
