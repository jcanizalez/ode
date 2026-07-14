#!/bin/sh
# Run the ODE unit tests with code coverage.
#
# Uses full Xcode explicitly: `xcode-select` often points at the Command Line
# Tools, which don't ship XCTest.

set -e
cd "$(dirname "$0")/.."

XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
if [ -z "$XCODE" ]; then
    echo "Full Xcode is required to run the tests but was not found in /Applications." >&2
    exit 1
fi
export DEVELOPER_DIR="$XCODE/Contents/Developer"

swift test --enable-code-coverage "$@"

# Print a per-file coverage summary for ODEKit.
PROF=".build/arm64-apple-macosx/debug/codecov/default.profdata"
BIN=".build/arm64-apple-macosx/debug/odePackageTests.xctest/Contents/MacOS/odePackageTests"
if [ -f "$PROF" ] && [ -f "$BIN" ]; then
    echo
    echo "Coverage (Sources/ODEKit):"
    xcrun llvm-cov report "$BIN" -instr-profile "$PROF" \
        -ignore-filename-regex="Tests|checkouts|CSherpa" 2>/dev/null
fi
