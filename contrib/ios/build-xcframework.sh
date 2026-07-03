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
#   IOS_SYSIMAGE_EXTRA_JL
#                     Space-separated list of .jl files to bake into
#                     the sysimage (see sysimage-ios.mk).
#   IOS_SYSIMAGE_EXTRA_PROJECT
#                     Path to a Project.toml/Manifest.toml directory
#                     whose packages should be baked into the sysimage
#                     and shipped as runtime resources next to the
#                     XCFramework (Project.toml, Manifest.toml,
#                     packages/<Name>/, artifacts/<sha>/).
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
         IOS_SYSIMAGE_EXTRA_JL="${IOS_SYSIMAGE_EXTRA_JL:-}" \
         IOS_SYSIMAGE_EXTRA_PROJECT="${IOS_SYSIMAGE_EXTRA_PROJECT:-}" \
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

# Stage the runtime resources that the iOS app needs alongside the
# XCFramework: stdlib tree (always), plus the user's extra project's
# Project.toml, Manifest.toml, package sources, and artifacts when
# IOS_SYSIMAGE_EXTRA_PROJECT is set.  These files are *not* part of
# the framework binary itself — they are loose files the embedding
# app ships in its bundle and points Julia at via JULIA_DEPOT_PATH /
# JULIA_LOAD_PATH (see contrib/ios/julia_ios_init.c).
package_runtime_resources() {
    local out="$OUTPUT_DIR/julia-runtime-resources"
    local host_julia="$JULIA_SRC/usr/bin/julia"
    local versdir
    versdir="v$(cut -d. -f1-2 < "$JULIA_SRC/VERSION")"

    echo
    echo "==> Staging runtime resources at $out"
    rm -rf "$out"
    mkdir -p "$out/share/julia/stdlib"

    # Empty bin/ so JULIA_BINDIR=<resources>/bin names a real directory.
    # julia_ios_init.c points JULIA_BINDIR here so Base's Sys.STDLIB, the
    # CA cert path, and Pkg's stdlib dir — all computed as
    # BINDIR/../share/julia/... — resolve into this tree.  Nothing needs to
    # live in bin/ (there is no julia executable on iOS); it only has to
    # exist so `<resources>/bin/../share` normalizes to `<resources>/share`.
    mkdir -p "$out/bin"

    # Stdlib trees (Project.toml + Manifest.toml + per-stdlib sources).
    # Julia looks for these under JULIA_BINDIR/../share/julia/stdlib/vX.Y/
    # (= <resources>/share/julia/stdlib/vX.Y here); bundle them there.
    # -L dereferences symlinks: the build tree's per-stdlib entries are
    # relative symlinks back into $JULIA_SRC/stdlib/, which dangle once the
    # tree is copied into an app bundle (and iOS bundles reject symlinks
    # at codesign time anyway).
    if [[ -d "$JULIA_SRC/usr/share/julia/stdlib/$versdir" ]]; then
        cp -RL "$JULIA_SRC/usr/share/julia/stdlib/$versdir" \
               "$out/share/julia/stdlib/$versdir"
    else
        echo "ERROR: stdlib tree missing at $JULIA_SRC/usr/share/julia/stdlib/$versdir" >&2
        exit 1
    fi

    # CA root certificates.  MozillaCACerts_jll computes the cert path as
    # JULIA_BINDIR/../share/julia/cert.pem; with JULIA_BINDIR=<resources>/bin
    # that resolves to this copy, so NetworkOptions / Downloads / LibGit2
    # find it with no extra env override.
    if [[ -f "$JULIA_SRC/usr/share/julia/cert.pem" ]]; then
        cp -L "$JULIA_SRC/usr/share/julia/cert.pem" "$out/share/julia/cert.pem"
    else
        echo "WARNING: cert.pem missing at $JULIA_SRC/usr/share/julia/cert.pem;" >&2
        echo "         TLS connections from the app may fail to verify peers." >&2
    fi

    # User project resources — only when an extra project was baked into
    # the sysimage.  Without these, Pkg can't resolve the packages whose
    # methods the sysimage already contains.
    if [[ -n "${IOS_SYSIMAGE_EXTRA_PROJECT:-}" ]]; then
        if [[ ! -f "$IOS_SYSIMAGE_EXTRA_PROJECT/Project.toml" ]]; then
            echo "ERROR: IOS_SYSIMAGE_EXTRA_PROJECT=$IOS_SYSIMAGE_EXTRA_PROJECT has no Project.toml" >&2
            exit 1
        fi
        cp "$IOS_SYSIMAGE_EXTRA_PROJECT/Project.toml" "$out/Project.toml"
        if [[ -f "$IOS_SYSIMAGE_EXTRA_PROJECT/Manifest.toml" ]]; then
            cp "$IOS_SYSIMAGE_EXTRA_PROJECT/Manifest.toml" "$out/Manifest.toml"
        fi

        # Enumerate every transitive dep via Pkg and copy its source
        # tree + any artifacts it pulled in.  Run with the same env vars
        # as the sysimage bake so dependency resolution sees the same
        # project + depot.
        JULIA_LOAD_PATH=@:@stdlib \
        JULIA_PROJECT="$IOS_SYSIMAGE_EXTRA_PROJECT" \
        "$host_julia" --startup-file=no - "$out" <<'JULIA'
        using Pkg, Pkg.Artifacts, SHA
        target = ARGS[1]
        mkpath(joinpath(target, "packages"))
        mkpath(joinpath(target, "artifacts"))
        # Copy every artifact listed in the (Julia)Artifacts.toml of `srcdir`
        # into the bundled depot's artifacts/ store.
        function copy_artifacts(srcdir, target)
            art_toml = joinpath(srcdir, "JuliaArtifacts.toml")
            isfile(art_toml) || (art_toml = joinpath(srcdir, "Artifacts.toml"))
            isfile(art_toml) || return
            for (name, entry) in Artifacts.load_artifacts_toml(art_toml)
                variants = entry isa Vector ? entry : [entry]
                for v in variants
                    sha = get(v, "git-tree-sha1", nothing)
                    sha === nothing && continue
                    src = try
                        Artifacts.artifact_path(Base.SHA1(sha))
                    catch
                        continue
                    end
                    isdir(src) || continue
                    adst = joinpath(target, "artifacts", sha)
                    isdir(adst) && continue
                    # Artifact trees (esp. JLLs) use symlink chains like
                    # libfoo.dylib -> libfoo.1.dylib; dereference those
                    # too, tolerating the occasional dangling link.
                    try
                        cp(src, adst; follow_symlinks=true)
                    catch err
                        @warn "skipping artifact $sha" err
                        isdir(adst) && rm(adst; recursive=true)
                    end
                end
            end
        end
        # The project itself may declare artifacts (Pkg.dependencies() only
        # covers its deps).
        copy_artifacts(dirname(Base.active_project()), target)
        for (uuid, info) in Pkg.dependencies()
            info.source === nothing && continue
            isdir(info.source) || continue
            # Preserve the depot layout `packages/<Name>/<HASH7>/` so
            # Pkg's source_path() can find the package by UUID at
            # runtime.  For regular registered packages, info.source
            # is `.../packages/<Name>/<HASH7>`, and `basename` gives
            # us the slug.
            slug = basename(info.source)
            dst = joinpath(target, "packages", info.name, slug)
            isdir(dst) && rm(dst; recursive=true)
            mkpath(dirname(dst))
            # follow_symlinks: same reason as the stdlib `cp -RL` above —
            # symlinks dangle in the app bundle and fail codesign.
            cp(info.source, dst; follow_symlinks=true)
            copy_artifacts(info.source, target)
        end
JULIA
    fi

    echo "    Resources:       $out"
    echo "    Total size:      $(du -sh "$out" | cut -f1)"
}
package_runtime_resources

echo
echo "==> Done."
echo "    XCFramework:     $OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
echo "    Device slice:    $DEVICE_FW"
echo "    Simulator slice: $SIM_FW"
echo "    Resources:       $OUTPUT_DIR/julia-runtime-resources"
