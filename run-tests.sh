#!/bin/zsh
set -euo pipefail
SOURCE_DIR="${0:A:h}"
TEST_DIR="$(mktemp -d /tmp/networkrepair-tests.XXXXXX)"
trap '/bin/rm -rf "$TEST_DIR"' EXIT
"$SOURCE_DIR/build.sh" "$TEST_DIR"
"$TEST_DIR/网络修复.app/Contents/MacOS/NetworkFirstAid" --self-test
/usr/bin/xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 "$SOURCE_DIR/NetworkDiagnostics.swift" "$SOURCE_DIR/tests/Diagnostics/main.swift" -o "$TEST_DIR/diagnostics-check"
"$TEST_DIR/diagnostics-check"
