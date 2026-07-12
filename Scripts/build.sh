#!/bin/sh
# Builds JXLCore (static lib + module) and the `jxl` CLI using swiftc directly.
#
# Why not `swift build`? The macOS 26/27 Command Line Tools ship a broken
# SwiftPM build service (dyld cannot resolve its bundled frameworks). The
# compiler itself is fine, so we drive it directly. Once full Xcode is
# installed, plain `swift build` / `swift test` work against Package.swift.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/manual"
mkdir -p "$BUILD"

CORE_SRC=$(find "$ROOT/Sources/JXLCore" -name '*.swift' | sort)

echo "==> Building JXLCore module + static library"
# shellcheck disable=SC2086
swiftc -O -parse-as-library \
    -module-name JXLCore \
    -emit-module -emit-module-path "$BUILD/JXLCore.swiftmodule" \
    -emit-library -static -o "$BUILD/libJXLCore.a" \
    $CORE_SRC

echo "==> Building JXLKit (CGImage bridge)"
KIT_SRC=$(find "$ROOT/Sources/JXLKit" -name '*.swift' | sort)
# shellcheck disable=SC2086
swiftc -O -parse-as-library \
    -module-name JXLKit \
    -I "$BUILD" \
    -emit-module -emit-module-path "$BUILD/JXLKit.swiftmodule" \
    -emit-library -static -o "$BUILD/libJXLKit.a" \
    $KIT_SRC

echo "==> Building jxl CLI"
swiftc -O \
    -module-name jxl \
    -I "$BUILD" -L "$BUILD" -lJXLCore \
    -o "$BUILD/jxl" \
    "$ROOT/Sources/jxl/main.swift"

echo "==> Done: $BUILD/jxl"
