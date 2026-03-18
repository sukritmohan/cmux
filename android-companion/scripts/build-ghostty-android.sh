#!/usr/bin/env bash
# Build libghostty-vt.so for Android targets.
#
# Prerequisites:
#   - Zig toolchain installed
#   - ghostty submodule initialized (../ghostty)
#
# Outputs:
#   android/app/src/main/jniLibs/arm64-v8a/libghostty-vt.so
#   android/app/src/main/jniLibs/x86_64/libghostty-vt.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$(cd "$PROJECT_DIR/../ghostty" && pwd)"
JNILIBS_DIR="$PROJECT_DIR/android/app/src/main/jniLibs"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "ERROR: ghostty directory not found at $GHOSTTY_DIR"
    echo "Run ./scripts/setup.sh from the repo root first."
    exit 1
fi

build_target() {
    local zig_target="$1"
    local abi_dir="$2"

    echo "Building libghostty-vt.so for $zig_target..."
    (
        cd "$GHOSTTY_DIR"
        zig build lib-vt \
            -Dtarget="$zig_target" \
            -Doptimize=ReleaseFast
    )

    local so_path="$GHOSTTY_DIR/zig-out/lib/libghostty-vt.so"
    if [ ! -f "$so_path" ]; then
        echo "ERROR: Build produced no output at $so_path"
        exit 1
    fi

    mkdir -p "$JNILIBS_DIR/$abi_dir"
    cp "$so_path" "$JNILIBS_DIR/$abi_dir/libghostty-vt.so"
    echo "Copied to $JNILIBS_DIR/$abi_dir/libghostty-vt.so"
}

echo "=== Building GhosttyKit VT for Android ==="

# ARM64 (primary — physical devices)
build_target "aarch64-linux-android" "arm64-v8a"

# x86_64 (emulator support — may fail, ARM64 is primary)
if build_target "x86_64-linux-android" "x86_64"; then
    echo "x86_64 build succeeded."
else
    echo "WARNING: x86_64 build failed. ARM64 is primary; use a physical device."
fi

echo ""
echo "=== Build complete ==="
echo "Libraries:"
find "$JNILIBS_DIR" -name "*.so" -exec ls -lh {} \;
