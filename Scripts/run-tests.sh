#!/bin/sh
# Compiles JXLCore together with the standalone TestRunner (single module, so
# internal API is reachable) and runs it. See Scripts/build.sh for why we avoid
# `swift test` on the current toolchain.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
mkdir -p "$BUILD"

CORE_SRC=$(find "$ROOT/Sources/JXLCore" -name '*.swift' | sort)

echo "==> Compiling test runner"
# shellcheck disable=SC2086
swiftc -parse-as-library -module-name JXLTests \
    -o "$BUILD/tests" \
    $CORE_SRC \
    "$ROOT/Tests/Standalone/TestRunner.swift"

echo "==> Running"
"$BUILD/tests" "$ROOT/Tests/JXLCoreTests/Fixtures"
