#!/bin/sh
# Builds the JXL Viewer macOS app (Apps/JXLViewer) into a runnable .app bundle
# using swiftc directly — no Xcode project required, matching the toolchain-light
# approach of Scripts/build.sh.
#
#   sh Scripts/build-viewer.sh          # build the .app
#   sh Scripts/build-viewer.sh --run    # build, then launch it
#
# Output: .build/viewer/JXLViewer.app
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/viewer"
APP="$BUILD/JXLViewer.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

mkdir -p "$BUILD"

CORE_SRC=$(find "$ROOT/Sources/JXLCore" -name '*.swift' | sort)
KIT_SRC=$(find "$ROOT/Sources/JXLKit" -name '*.swift' | sort)
APP_SRC=$(find "$ROOT/Apps/JXLViewer" -name '*.swift' | sort)

echo "==> Building JXLCore module + static library"
# shellcheck disable=SC2086
swiftc -O -parse-as-library \
    -module-name JXLCore \
    -emit-module -emit-module-path "$BUILD/JXLCore.swiftmodule" \
    -emit-library -static -o "$BUILD/libJXLCore.a" \
    $CORE_SRC

echo "==> Building JXLKit module + static library"
# shellcheck disable=SC2086
swiftc -O -parse-as-library \
    -module-name JXLKit \
    -I "$BUILD" -L "$BUILD" -lJXLCore \
    -emit-module -emit-module-path "$BUILD/JXLKit.swiftmodule" \
    -emit-library -static -o "$BUILD/libJXLKit.a" \
    $KIT_SRC

echo "==> Compiling JXLViewer executable"
# shellcheck disable=SC2086
swiftc -O \
    -module-name JXLViewer \
    -I "$BUILD" -L "$BUILD" -lJXLKit -lJXLCore \
    -framework AppKit -framework Metal -framework CoreGraphics \
    -o "$BUILD/JXLViewer" \
    $APP_SRC

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BUILD/JXLViewer" "$MACOS_DIR/JXLViewer"
cp "$ROOT/Apps/JXLViewer/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc code signature so macOS is willing to launch the bundle locally.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> Done: $APP"

if [ "${1:-}" = "--run" ]; then
    shift
    echo "==> Launching"
    exec "$MACOS_DIR/JXLViewer" "$@"
fi
