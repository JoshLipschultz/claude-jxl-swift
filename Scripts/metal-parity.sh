#!/bin/sh
# Validates the GPU display-time color converter (JXLKit JXLMetalColorConverter)
# against the CPU reference (jxlXYBToLinearPlanes): decodes lossy XYB fixtures,
# runs both, and checks the linear-light output matches to < 1e-4 absolute
# (GPU vs CPU float32 differ only by FMA / mul-order). Needs a Metal device;
# prints NO_METAL and skips if none is present. Separate from run-tests.sh
# because it links JXLKit + Metal, not just JXLCore.
#
#   sh Scripts/metal-parity.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/metal-parity"
mkdir -p "$BUILD"

CORE_SRC=$(find "$ROOT/Sources/JXLCore" -name '*.swift' | sort)
KIT_SRC=$(find "$ROOT/Sources/JXLKit" -name '*.swift' | sort)

echo "==> Building JXLCore + JXLKit"
# shellcheck disable=SC2086
swiftc -O -parse-as-library -module-name JXLCore \
    -emit-module -emit-module-path "$BUILD/JXLCore.swiftmodule" \
    -emit-library -static -o "$BUILD/libJXLCore.a" $CORE_SRC
# shellcheck disable=SC2086
swiftc -O -parse-as-library -module-name JXLKit -I "$BUILD" -L "$BUILD" -lJXLCore \
    -emit-module -emit-module-path "$BUILD/JXLKit.swiftmodule" \
    -emit-library -static -o "$BUILD/libJXLKit.a" $KIT_SRC

echo "==> Building parity harness"
swiftc -O -I "$BUILD" -L "$BUILD" -lJXLKit -lJXLCore -framework Metal \
    "$ROOT/Tests/Metal/MetalParity.swift" -o "$BUILD/metal-parity"

FIX="$ROOT/Tests/JXLCoreTests/Fixtures"
echo "==> Running parity"
exec "$BUILD/metal-parity" \
    "$FIX/128x128_pdc2.jxl" \
    "$FIX/384x256_prog.jxl" \
    "$FIX/384x256_progq.jxl" \
    "$FIX/96x64_ecups.jxl" \
    "$FIX/96x64_alpha16.jxl" \
    "$@"
