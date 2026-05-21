#!/usr/bin/env bash
# build-xcframework.sh — build a Julia.xcframework that combines iphoneos
# and iphonesimulator slices.  Each slice is a full out-of-tree build
# (~30-60 min) because the deps (LLVM, OpenLibm, ...) are compiled per
# platform.
#
# Usage:
#   contrib/ios/build-xcframework.sh [output-dir]
#
# Environment overrides:
#   JOBS              Parallel jobs (default: $(sysctl -n hw.ncpu))
#   JULIA_SRC         Julia source tree (default: detected from script location)
#   IOS_VERSION_MIN   Minimum iOS version (default: 14.0)
#   FRAMEWORK_NAME    Framework display name (default: Julia)
#   DEVICE_BUILDDIR   Out-of-tree dir for the device slice
#                     (default: $JULIA_SRC/build-ios-device)
#   SIM_BUILDDIR      Out-of-tree dir for the simulator slice
#                     (default: $JULIA_SRC/build-ios-sim)
#
# Limitations:
#   - The simulator slice is arm64 only (Apple-silicon Macs).  Intel-Mac
#     simulator support would need a third build with -arch x86_64 and a
#     `lipo`-merge step before xcodebuild.
#   - Codesigning is delegated to the per-slice contrib/ios/Makefile
#     `framework` target; xcodebuild -create-xcframework does not sign.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULIA_SRC="${JULIA_SRC:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
IOS_VERSION_MIN="${IOS_VERSION_MIN:-14.0}"
FRAMEWORK_NAME="${FRAMEWORK_NAME:-Julia}"
DEVICE_BUILDDIR="${DEVICE_BUILDDIR:-$JULIA_SRC/build-ios-device}"
SIM_BUILDDIR="${SIM_BUILDDIR:-$JULIA_SRC/build-ios-sim}"
OUTPUT_DIR="${1:-$JULIA_SRC/build-ios}"

# Preflight
[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: requires macOS" >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "ERROR: install Xcode" >&2; exit 1; }
xcrun --sdk iphoneos        --show-sdk-path >/dev/null 2>&1 || { echo "ERROR: iphoneos SDK not found" >&2; exit 1; }
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || { echo "ERROR: iphonesimulator SDK not found" >&2; exit 1; }

# Ensure the in-tree host julia exists.  Both iOS slices share this single
# host julia for sysimage bake; the iOS builds themselves run out-of-tree
# (DEVICE_BUILDDIR / SIM_BUILDDIR), so the host's $JULIA_SRC/usr/ is not
# clobbered by either iOS slice.
ensure_host_julia() {
    local host_julia="$JULIA_SRC/usr/bin/julia"
    if [[ -x "$host_julia" ]]; then
        echo "==> Using in-tree host julia at $host_julia"
        return
    fi
    echo
    echo "==> Host julia not found at $host_julia"
    echo "==> Running in-tree host build (one-time, shared by both iOS slices)"
    echo "    JOBS=$JOBS"
    make -C "$JULIA_SRC" -j "$JOBS"
    [[ -x "$host_julia" ]] || {
        echo "ERROR: host build completed but $host_julia is still missing" >&2
        exit 1
    }
}
ensure_host_julia

build_slice() {
    local platform="$1"
    local builddir="$2"
    local install_prefix="$builddir/install"

    echo
    echo "==> Building $platform slice in $builddir"
    echo "    JOBS=$JOBS  IOS_VERSION_MIN=$IOS_VERSION_MIN"

    # Seed the out-of-tree build dir on first run.
    if [[ ! -f "$builddir/Make.inc" ]]; then
        make -C "$JULIA_SRC" O="$builddir" configure
    fi

    # Build the libraries + iOS sysimage (default julia-release on iOS now
    # includes a sysimg-ios pass driven by sysimage-ios.mk, which uses a host
    # julia for the bake stages and --target=arm64-apple-iosX for cross-emit).
    # Set NO_SYSIMAGE=1 for a libraries-only build.
    make -C "$builddir" \
         IOS=1 IOS_PLATFORM="$platform" IOS_VERSION_MIN="$IOS_VERSION_MIN" \
         IOS_FRAMEWORK_NAME="$FRAMEWORK_NAME" \
         -j "$JOBS" \
         julia-release

    # Bundle the libraries into a .framework at $install_prefix/$FRAMEWORK_NAME.framework.
    make -C "$JULIA_SRC/contrib/ios" \
         BUILDROOT="$builddir" prefix="$install_prefix" \
         IOS=1 IOS_PLATFORM="$platform" IOS_VERSION_MIN="$IOS_VERSION_MIN" \
         IOS_FRAMEWORK_NAME="$FRAMEWORK_NAME" \
         framework
}

build_slice iphoneos        "$DEVICE_BUILDDIR"
build_slice iphonesimulator "$SIM_BUILDDIR"

DEVICE_FW="$DEVICE_BUILDDIR/install/${FRAMEWORK_NAME}.framework"
SIM_FW="$SIM_BUILDDIR/install/${FRAMEWORK_NAME}.framework"
[[ -d "$DEVICE_FW" ]] || { echo "ERROR: device framework missing at $DEVICE_FW" >&2; exit 1; }
[[ -d "$SIM_FW"    ]] || { echo "ERROR: simulator framework missing at $SIM_FW" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"

echo
echo "==> Combining slices into $OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
xcodebuild -create-xcframework \
    -framework "$DEVICE_FW" \
    -framework "$SIM_FW" \
    -output    "$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"

echo
echo "==> Done."
echo "    XCFramework:     $OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
echo "    Device slice:    $DEVICE_FW"
echo "    Simulator slice: $SIM_FW"
