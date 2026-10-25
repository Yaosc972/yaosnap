#!/bin/bash
# CLI 验收：只验证参数、退出码与 URL 契约，不启动真实 app 的 GUI 交互。
set -uo pipefail
cd "$(dirname "$0")/../.."

if ! ./build.sh; then
    echo "SUMMARY passes=0 failures=1"
    exit 1
fi

BIN="$PWD/.build/release/snip"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }

[ -x "$BIN" ] && pass "snip binary exists" || fail "snip binary exists"
[ -d "$PWD/Build/Yaosnap.app" ] && pass "app bundle exists" || fail "app bundle exists"

OUT="$("$BIN" --help 2>&1)"
CODE=$?
[ "$CODE" -eq 0 ] && pass "help exits 0" || fail "help exits $CODE"
case "$OUT" in
    *用法*) pass "help prints usage" ;;
    *) fail "help prints usage" ;;
esac

for ARGS in "bogus" "-o" "--pos 1" "--pos left 2"; do
    "$BIN" $ARGS >/dev/null 2>&1
    CODE=$?
    [ "$CODE" -ne 0 ] && pass "invalid args '$ARGS' exits $CODE" || fail "invalid args '$ARGS' exits 0"
done

grep -q 'application(_ application: NSApplication, open urls: \[URL\])' Sources/Yaosnap/AppDelegate.swift \
    && pass "AppDelegate implements application(_:open:)" \
    || fail "AppDelegate implements application(_:open:)"
grep -q 'commandRouter.handle(url)' Sources/Yaosnap/AppDelegate.swift \
    && pass "AppDelegate routes URLs" \
    || fail "AppDelegate routes URLs"
grep -q '<string>yaosnap</string>' Resources/Info.plist \
    && pass "Info.plist registers yaosnap scheme" \
    || fail "Info.plist registers yaosnap scheme"

mkdir -p /tmp/yaosnap-verify/build
swiftc -O -target "$(uname -m)-apple-macos12.0" \
    -I "$PWD/.build/release" \
    Tools/verify/CLIE2E.swift \
    "$PWD/.build/release/YaosnapCore.o" \
    -o /tmp/yaosnap-verify/build/cliharness
COMPILE_CODE=$?
if [ "$COMPILE_CODE" -ne 0 ]; then
    fail "compile URL contract harness"
else
    HARNESS_OUT="$(/tmp/yaosnap-verify/build/cliharness)"
    echo "$HARNESS_OUT"
    HARNESS_PASSES="$(echo "$HARNESS_OUT" | sed -n 's/^HARNESS passes=\([0-9]*\) failures=.*/\1/p')"
    HARNESS_FAILURES="$(echo "$HARNESS_OUT" | sed -n 's/^HARNESS passes=[0-9]* failures=\([0-9]*\)$/\1/p')"
    PASS=$((PASS + ${HARNESS_PASSES:-0}))
    FAIL=$((FAIL + ${HARNESS_FAILURES:-0}))
fi

echo "SUMMARY passes=$PASS failures=$FAIL"
[ "$FAIL" -eq 0 ]
