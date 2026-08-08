#!/usr/bin/env bash
# build-xcframework.sh — build the Julia XCFramework SET combining iphoneos
# and iphonesimulator slices.  Each slice is a full out-of-tree build
# (~30-60 min) because the deps (LLVM, OpenLibm, ...) are compiled per
# platform.
#
# App Store rule: apps may not contain loose dylibs — every dynamic library
# must be its own single-binary framework.  Each slice therefore produces a
# Frameworks/ directory (Julia.framework plus one framework per dependency
# dylib and JuliaSysimage.framework; see contrib/ios/Makefile), and this
# script emits one .xcframework per framework name into
# <output-dir>/xcframeworks/.  Embed & Sign EVERY xcframework in the app;
# link only Julia.xcframework (it is the only one with headers).
#
# Usage:
#   contrib/ios/build-xcframework.sh [output-dir]
#
# Environment overrides:
#   JOBS              Parallel jobs (default: $(sysctl -n hw.ncpu))
#   JULIA_SRC         Julia source tree (default: detected from script location)
#   IOS_VERSION_MIN   Minimum iOS version (default: 16.4 — the floor for
#                     Accelerate's ILP64 BLAS/LAPACK; see APPSTORE.md)
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
#   REBUILD_SYSIMAGE  When set (=1), force the sysimage to rebuild before
#                     each slice's `make`, without a clean.  The baked
#                     sysimage (sys-o.a / sys.dylib) does NOT list your
#                     IOS_SYSIMAGE_EXTRA_JL / _EXTRA_PROJECT as makefile
#                     prerequisites, so editing those does not by itself
#                     invalidate it — `make` would reuse the stale image.
#                     This removes the stage-3/4 outputs so `make` rebakes
#                     them with the current extras; the expensive base
#                     sysbase.ji and the platform libraries are kept, so the
#                     rebuild only re-runs the (few-minute) bake, not a
#                     full ~30-60 min slice build.
#
# Getting a usable log out of a failed build:
#   Nothing here redirects output, so a failure is on your terminal — but
#   under `-j$JOBS` the real error is buried thousands of lines above the
#   final `*** Error` and the top-level make runs `-s`, which hides which
#   dependency was even building.  Do not re-run this script to find out.
#   Re-run just the failing stage, serially and verbosely, in the slice's
#   build directory; every dependency that already succeeded left a
#   `build-compiled` stamp, so make resumes at the one that failed:
#
#     make -C build-ios-device \
#          IOS=1 IOS_PLATFORM=iphoneos IOS_VERSION_MIN=16.4 \
#          VERBOSE=1 -j1 julia-deps 2>&1 | tee /tmp/ios-deps.log
#
#   (`build-ios-sim` / `IOS_PLATFORM=iphonesimulator` for the other slice.)
#   VERBOSE=1 drops `-s` and echoes every command, and `-j1` puts the error
#   at the end of the log instead of interleaved.  Then:
#
#     grep -n -iE 'error|\*\*\*' /tmp/ios-deps.log | tail -40
#
#   A CMake dependency (LLVM, libunwind) that fails during *configuration*
#   reports the reason in `CMakeFiles/CMakeError.log` under its build
#   directory rather than on stdout — that is
#   build-ios-device/deps/llvm-<ver>/build_Release/ for LLVM and
#   build-ios-device/deps/<name>-<ver>/ for the rest.  An autoconf
#   dependency (GMP, MPFR) leaves `config.log` in the same place.
#   Sources are shared across slices in $JULIA_SRC/deps/srccache/, so a
#   failure that is really a bad patch or a truncated download shows up
#   identically in both slices.
#
#   A failure whose target is a tarball rather than an object file, e.g.
#
#     make[1]: *** [.../deps/srccache/gmp-6.3.0.tar.bz2] Error 28
#
#   is a download, not a compile: that number is curl's exit status, and 28
#   is a timeout (deps/tools/jldownload gives it --connect-timeout 15 -y 15,
#   so a mirror averaging under a byte a second for 15s is abandoned).  It
#   tries cache.julialang.org first and the upstream URL second, but the
#   versions bumped for iOS — GMP, MPFR, OpenLibm, zlib, blastrampoline —
#   are newer than anything release-1.10 CI ever fetched, so the cache does
#   not hold them and both attempts land on the same mirror.  Retrying
#   usually works.  Delete the partial file first: deps/Makefile sets no
#   .DELETE_ON_ERROR, so make would treat the truncated tarball as up to
#   date and fail later in source-extracted with a decompression error
#   instead.  To seed it by hand, download to $JULIA_SRC/deps/srccache/ and
#   check it against the recorded digest with `make -C deps checksum-<name>`.
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
IOS_VERSION_MIN="${IOS_VERSION_MIN:-16.4}"
FRAMEWORK_NAME="${FRAMEWORK_NAME:-Julia}"
DEVICE_BUILDDIR="${DEVICE_BUILDDIR:-$JULIA_SRC/build-ios-device}"
SIM_BUILDDIR="${SIM_BUILDDIR:-$JULIA_SRC/build-ios-sim}"
REBUILD_SYSIMAGE="${REBUILD_SYSIMAGE:-}"
# Which slices to build.  Both by default, because that is what an app
# needs; a single slice is for iteration -- notably SLICES=iphonesimulator,
# which is the only configuration that can actually be *run* without a
# device.  A one-slice xcframework is valid, just not universal.
SLICES="${SLICES:-iphoneos iphonesimulator}"
OUTPUT_DIR="${1:-$JULIA_SRC/build-ios}"

# xcodebuild's -debug-symbols requires absolute paths; normalize overrides.
[[ "$DEVICE_BUILDDIR" = /* ]] || DEVICE_BUILDDIR="$PWD/$DEVICE_BUILDDIR"
[[ "$SIM_BUILDDIR"    = /* ]] || SIM_BUILDDIR="$PWD/$SIM_BUILDDIR"
[[ "$OUTPUT_DIR"      = /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"

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

    # Seed the out-of-tree build dir on first run.  Probe for the Makefile
    # configure actually writes: it creates $builddir/Makefile (plus one per
    # build subdirectory, sysimage.mk and pkgimage.mk) and never a Make.inc,
    # so probing for that ran configure on every invocation -- fine the first
    # time on an empty directory, and a hang or a failure afterwards, because
    # configure prompts for confirmation once the directory is not empty.
    # `yes` answers that prompt for the case where the directory exists but
    # was never configured, which has no tty in CI.
    if [[ ! -f "$builddir/Makefile" ]]; then
        yes | make -C "$JULIA_SRC" O="$builddir" configure
    fi

    # Force a sysimage rebuild when asked.  IOS_SYSIMAGE_EXTRA_JL / _EXTRA_PROJECT
    # are consumed at bake time but are not makefile prerequisites of the baked
    # sysimage, so editing them leaves `make` thinking sys-o.a / sys.dylib are
    # up to date.  Remove just the stage-3 (extras baked here) and stage-4
    # outputs; the base sysbase.ji (stage 2, extras-independent) and the platform
    # libraries stay, so `make` below only re-runs the bake, not a full build.
    if [[ -n "$REBUILD_SYSIMAGE" ]]; then
        local jldir="$builddir/usr/lib/julia"
        echo "    REBUILD_SYSIMAGE=1: removing baked sysimage in $jldir"
        rm -f "$jldir/sys-o.a" "$jldir/sys-debug-o.a" \
              "$jldir/sys.dylib" "$jldir/sys-debug.dylib"
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

    # Bundle the libraries into per-dylib frameworks at $install_prefix/Frameworks/.
    make -C "$JULIA_SRC/contrib/ios" \
         BUILDROOT="$builddir" prefix="$install_prefix" \
         IOS=1 IOS_PLATFORM="$platform" IOS_VERSION_MIN="$IOS_VERSION_MIN" \
         IOS_FRAMEWORK_NAME="$FRAMEWORK_NAME" \
         framework
}

slice_builddir() {
    case "$1" in
        iphoneos)        echo "$DEVICE_BUILDDIR" ;;
        iphonesimulator) echo "$SIM_BUILDDIR" ;;
        *) echo "ERROR: unknown slice '$1' (want iphoneos or iphonesimulator)" >&2
           exit 1 ;;
    esac
}

for slice in $SLICES; do
    build_slice "$slice" "$(slice_builddir "$slice")"
done

for slice in $SLICES; do
    fwks="$(slice_builddir "$slice")/install/Frameworks"
    [[ -d "$fwks/${FRAMEWORK_NAME}.framework" ]] || \
        { echo "ERROR: $slice frameworks missing at $fwks" >&2; exit 1; }
done

XCFW_DIR="$OUTPUT_DIR/xcframeworks"
mkdir -p "$OUTPUT_DIR"
rm -rf "$XCFW_DIR"
mkdir -p "$XCFW_DIR"
# Remove the pre-frameworks-split single xcframework if present, so stale
# layouts don't linger next to the new output.
rm -rf "$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"

# The first requested slice decides the framework list; every other slice has
# to carry the same names, since an xcframework is per-framework.
FIRST_SLICE="${SLICES%% *}"
FIRST_FWKS="$(slice_builddir "$FIRST_SLICE")/install/Frameworks"

echo
echo "==> Combining slices into $XCFW_DIR (one xcframework per framework)"
for fw in "$FIRST_FWKS"/*.framework; do
    name="$(basename "$fw" .framework)"
    # Embed per-slice dSYMs (produced by the Makefile's `dsyms` step) so
    # Xcode copies them into app archives — this is what satisfies App Store
    # Connect's "Upload Symbols" check for each embedded framework UUID.
    # -debug-symbols requires absolute paths and must follow the -framework
    # it belongs to.
    args=()
    for slice in $SLICES; do
        slicedir="$(slice_builddir "$slice")"
        slicefw="$slicedir/install/Frameworks/$name.framework"
        if [[ ! -d "$slicefw" ]]; then
            echo "ERROR: $name.framework is in the $FIRST_SLICE slice but not $slice" >&2
            exit 1
        fi
        args+=( -framework "$slicefw" )
        dsym="$slicedir/install/Frameworks-dSYMs/$name.framework.dSYM"
        [[ -d "$dsym" ]] && args+=( -debug-symbols "$dsym" )
    done
    echo "    $name.xcframework"
    xcodebuild -create-xcframework "${args[@]}" \
        -output "$XCFW_DIR/$name.xcframework" >/dev/null
done

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
        # --pkgimages=no: this only reads the manifest, but keep it
        # consistent with the bake so nothing tries to link a pkgimage.
        JULIA_LOAD_PATH=@:@stdlib \
        JULIA_PROJECT="$IOS_SYSIMAGE_EXTRA_PROJECT" \
        "$host_julia" --startup-file=no --pkgimages=no - "$out" <<'JULIA'
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

# Report any build-machine absolute path that made it into what the app
# ships.  Advisory by default (the baked stdlib source paths are inherent —
# see check-host-paths.sh); set IOS_STRICT_PATH_AUDIT=1 to fail on those too.
echo
"$SCRIPT_DIR/check-host-paths.sh" "$OUTPUT_DIR" || {
    echo
    echo "WARNING: the audit above found build-host paths in the shipped" >&2
    echo "         artifacts.  See contrib/ios/check-host-paths.sh." >&2
}

echo
echo "==> Done."
echo "    XCFrameworks:    $XCFW_DIR ($(ls -d "$XCFW_DIR"/*.xcframework 2>/dev/null | wc -l | tr -d ' ') total)"
echo "    Device slice:    $DEVICE_FWKS"
echo "    Simulator slice: $SIM_FWKS"
echo "    Resources:       $OUTPUT_DIR/julia-runtime-resources"
echo
echo "    Embed & Sign EVERY xcframework under xcframeworks/ in the app"
echo "    target; link only ${FRAMEWORK_NAME}.xcframework (the one with headers)."
