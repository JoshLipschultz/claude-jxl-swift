#!/bin/sh
# Compiles JXLCore together with the mutation fuzzer (single module, like
# run-tests.sh) and runs it over the fixture corpus. Any process trap is a
# bug: garbage input must produce a thrown JXLError, never a crash. On a
# crash, /tmp/jxl-fuzz-status names the fixture + seed; reproduce with
#   .build/manual/fuzz Tests/JXLCoreTests/Fixtures --repro <fixture> <seed>
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
mkdir -p "$BUILD"

CORE_SRC=$(find "$ROOT/Sources/JXLCore" -name '*.swift' | sort)

echo "==> Compiling fuzz runner"
# shellcheck disable=SC2086
swiftc -O -parse-as-library -module-name JXLFuzz \
    -o "$BUILD/fuzz" \
    $CORE_SRC \
    "$ROOT/Tests/Fuzz/FuzzRunner.swift"

echo "==> Fuzzing (${1:-300} iterations per fixture)"
"$BUILD/fuzz" "$ROOT/Tests/JXLCoreTests/Fixtures" "${1:-300}"
