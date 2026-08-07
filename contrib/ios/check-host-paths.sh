#!/usr/bin/env bash
# check-host-paths.sh — report build-machine absolute paths that survived into
# the artifacts an iOS app actually ships.
#
# Why this exists: a path that does not exist on the device is *skipped* at
# runtime, so a leaked build path is usually invisible in behaviour.  What it
# is not is invisible in the binary — it publishes the developer's username
# and directory layout in something that goes through App Store review, and it
# is a reliable signal that some part of the build is not relocatable.  This
# script makes both visible before submission instead of after.
#
# Usage:
#   contrib/ios/check-host-paths.sh <output-dir> [prefix ...]
#
# <output-dir> is the directory build-xcframework.sh wrote, i.e. the one
# containing xcframeworks/ and julia-runtime-resources/.  Extra arguments are
# additional absolute prefixes to search for; by default the script looks for
# $HOME, $JULIA_SRC (when set) and the generic "/Users/<name>/" shape.
#
# Exit status:
#   0  no hits, or hits only in the known-inherent category (see below) and
#      IOS_STRICT_PATH_AUDIT is unset
#   1  hits that are not in the known-inherent category, or any hit at all
#      when IOS_STRICT_PATH_AUDIT=1
#
# Known-inherent category: Julia records the absolute path of every stdlib
# source file it bakes (`Method.file`, plus `Sys.BUILD_STDLIB_PATH`), and
# rewrites them to the *runtime* stdlib location only when displaying them —
# see `Base.fixup_stdlib_path` in base/methodshow.jl.  Those strings are
# therefore in JuliaSysimage by construction, and no amount of init-time
# cleanup removes them.  The only way to keep a username out of them is to
# build from a directory that has no username in its path, e.g.
#
#     sudo mkdir -p /opt/julia-ios && sudo chown "$USER" /opt/julia-ios
#     git clone <this repo> /opt/julia-ios/julia
#
# and run the whole build (host julia included) from there.  Re-run this
# script afterwards to confirm.

set -uo pipefail

OUT="${1:-}"
if [[ -z "$OUT" || ! -d "$OUT" ]]; then
    echo "usage: $0 <output-dir> [extra-prefix ...]" >&2
    echo "  <output-dir> is build-xcframework.sh's output (has xcframeworks/)" >&2
    exit 2
fi
shift || true

RESOURCES="$OUT/julia-runtime-resources"
XCFW_DIR="$OUT/xcframeworks"

# Prefixes to hunt for.  Deduplicate and drop empties; a bare "/" or "$HOME"
# that expanded to nothing would match everything.
prefixes=()
add_prefix() {
    local p="$1"
    [[ -n "$p" && "$p" != "/" ]] || return 0
    local existing
    for existing in ${prefixes+"${prefixes[@]}"}; do
        [[ "$existing" == "$p" ]] && return 0
    done
    prefixes+=("$p")
}
add_prefix "${HOME:-}"
add_prefix "${JULIA_SRC:-}"
for extra in "$@"; do add_prefix "$extra"; done
# The generic shape, so a build done under someone else's home is still caught.
add_prefix "/Users/"

echo "==> Auditing shipped artifacts for build-host paths"
echo "    output dir: $OUT"
echo "    prefixes:   ${prefixes[*]}"
echo

# Escape a prefix for use in a regex.  Binaries are matched with `grep -F` on
# whole `strings` output lines, but text files can have very long lines, so
# there we extract the offending path itself — which needs a pattern.
esc_re() { printf '%s' "$1" | sed -e 's/[][\.*^$(){}?+|/]/\\&/g'; }

# `strings` on a Mach-O reports the whole file; that is what we want, since a
# leaked path can live in __cstring, in Julia's serialized string data, or in
# a load command.  Universal/xcframework binaries are handled by walking the
# per-slice framework binaries.
scan_binary() {
    local bin="$1" pref hits
    for pref in "${prefixes[@]}"; do
        hits="$(strings -a -- "$bin" 2>/dev/null | grep -F -- "$pref" | sort -u)" || true
        [[ -n "$hits" ]] || continue
        printf '%s\n' "$hits" | while IFS= read -r line; do
            printf '%s\t%s\n' "$bin" "$line"
        done
    done
}

RAW="$(mktemp "${TMPDIR:-/tmp}/julia-ios-path-audit.XXXXXX")" || {
    echo "ERROR: could not create a temporary file" >&2; exit 2; }
trap 'rm -f "$RAW"' EXIT

# 1. Every Mach-O inside the xcframeworks (all slices).  A framework binary is
# <name>.framework/<name> with no extension, so exclude the resource files.
if [[ -d "$XCFW_DIR" ]]; then
    while IFS= read -r bin; do
        scan_binary "$bin"
    done < <(find "$XCFW_DIR" -type f -perm -u+r \
                  -path '*.framework/*' ! -name '*.plist' ! -name '*.h' \
                  ! -name '*.modulemap' ! -name '*.xcprivacy' ! -path '*/Headers/*' \
                  ! -path '*/Modules/*' ! -path '*.dSYM/*') >> "$RAW"
else
    echo "NOTE: no xcframeworks/ under $OUT — skipping binary scan" >&2
fi

# 2. The loose resources tree (stdlib sources, Project/Manifest, artifacts).
if [[ -d "$RESOURCES" ]]; then
    for pref in "${prefixes[@]}"; do
        pref_re="$(esc_re "$pref")"
        while IFS= read -r f; do
            grep -h -o -E -- "$pref_re[^\"',[:space:]]*" "$f" 2>/dev/null | sort -u |
                while IFS= read -r line; do printf '%s\t%s\n' "$f" "$line"; done
        done < <(grep -rlI -F -- "$pref" "$RESOURCES" 2>/dev/null) >> "$RAW"
    done
else
    echo "NOTE: no julia-runtime-resources/ under $OUT — skipping resources scan" >&2
fi

if [[ ! -s "$RAW" ]]; then
    echo "OK: no build-host paths found in the shipped artifacts."
    exit 0
fi

# Split hits into the inherent stdlib-source-path category and everything else.
# A stdlib source path looks like <build-prefix>/.../share/julia/stdlib/vX.Y/...
# or <build-prefix>/.../stdlib/<Name>-<sha>/... (the vendored external stdlib
# checkouts the sysimage bakes from).
# Classify on the leaked path (field 2), never on the file it was found in —
# every hit in the resources tree lives under .../share/julia/stdlib/vX.Y/.
INHERENT_RE='(share/julia/stdlib/v[0-9]+\.[0-9]+|/stdlib/[A-Za-z0-9_]+-[0-9a-f]{40})'
INHERENT="$(awk -F'\t' -v re="$INHERENT_RE" '$2 ~ re' "$RAW" | sort -u)" || true
OTHER="$(awk -F'\t' -v re="$INHERENT_RE" '$2 !~ re' "$RAW" | sort -u)" || true

status=0

if [[ -n "$OTHER" ]]; then
    echo "FAIL: build-host paths that should not be here:"
    echo
    printf '%s\n' "$OTHER" | sed 's/^/    /'
    echo
    status=1
fi

if [[ -n "$INHERENT" ]]; then
    n=$(printf '%s\n' "$INHERENT" | wc -l | tr -d ' ')
    echo "NOTE: $n baked stdlib source paths (inherent — see the header of this"
    echo "      script; fix by building from a username-free directory):"
    echo
    printf '%s\n' "$INHERENT" | head -10 | sed 's/^/    /'
    [[ "$n" -gt 10 ]] && echo "    ... and $((n - 10)) more"
    echo
    if [[ -n "${IOS_STRICT_PATH_AUDIT:-}" ]]; then
        echo "      IOS_STRICT_PATH_AUDIT is set — treating these as failures."
        status=1
    fi
fi

[[ "$status" -eq 0 ]] && echo "OK: nothing outside the inherent category."
exit "$status"
