#!/bin/sh
# Compiles JXLCore together with the encoder-input fuzzer (single module,
# like fuzz.sh) and runs seeded random images through encode -> decode
# bit-exact round-trips across every (effort, backend) combination. Any
# mismatch, rejection, or trap is a bug; /tmp/jxl-encode-fuzz-status names
# the seed. Reproduce with:
#   .build/manual/fuzz-encode --repro <seed>
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
mkdir -p "$BUILD"

CORE_SRC=$(find "$ROOT/Sources/JXLCore" -name '*.swift' | sort)

echo "==> Compiling encode fuzzer"
# shellcheck disable=SC2086
swiftc -O -parse-as-library -module-name JXLEncodeFuzz \
    -o "$BUILD/fuzz-encode" \
    $CORE_SRC \
    "$ROOT/Tests/Fuzz/EncodeFuzzRunner.swift"

echo "==> Encode-fuzzing (${1:-400} random images)"
"$BUILD/fuzz-encode" "${1:-400}"
