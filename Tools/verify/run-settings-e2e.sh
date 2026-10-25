#!/bin/bash
# 编译并运行设置窗口验收 harness：真实构造 SettingsWindowController，
# 验证控件数量、热键录制、Esc 取消、失败标红与 UserDefaults 回写。
set -euo pipefail
cd "$(dirname "$0")/../.."

./build.sh

mkdir -p /tmp/yaosnap-verify/build

swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Sources/Yaosnap/Settings/SettingsWindowController.swift \
    Tools/verify/SettingsE2E.swift \
    "$PWD/.build/release/YaosnapCore.o" \
    -o /tmp/yaosnap-verify/build/settingsharness

/tmp/yaosnap-verify/build/settingsharness
