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

# Classify on the leaked path (field 2), never on the file it was found in —
# every hit in the resources tree lives under .../share/julia/stdlib/vX.Y/.
#
# Three kinds, only one of which is a defect:
#
#  * Not this machine's at all.  The generic "/Users/" net also catches string
#    literals shaped like paths -- a Pkg test fixture naming /Users/test, a
#    docstring quoting file:///C:/Users/user/... -- which are content, not
#    leakage.  Anything not under a prefix that names *this* build tree is
#    reported and otherwise ignored.
#  * Inherent.  Julia records the absolute path of every source file it bakes,
#    so each one shows up as a string: stdlib sources, the top-level Compiler
#    that 1.12 moved to share/julia/Compiler, and the base files generated into
#    the build directory (build_h.jl and friends).  Any `.jl` under the build
#    tree is one of these.  The build root on its own is the same thing with
#    nothing appended.
#  * Everything else, which is the interesting case: a path with a component
#    after it that is not a source file is something the runtime would try to
#    *open* -- a JLL LIBPATH, an artifact or depot directory, a dylib.
specific_re=""
for pref in "${prefixes[@]}"; do
    [[ "$pref" == "/Users/" ]] && continue
    # Unanchored: a binary's hit is the whole `strings` line, so the path can
    # sit behind a label -- OpenSSL emits `OPENSSLDIR: "/…"`.
    specific_re="${specific_re:+$specific_re|}$(esc_re "$pref")"
done
roots_re=""
for pref in "${prefixes[@]}"; do
    [[ "$pref" == "/Users/" ]] && continue
    roots_re="${roots_re:+$roots_re|}^$(esc_re "${pref%/}")/?$"
done
# Source files in any language: a compiler records __FILE__ the way Julia
# records Method.file, so SuiteSparse's assertions carry .c paths for the same
# reason the sysimage carries .jl ones.  Allow trailing punctuation, because a
# binary's strings line is matched whole and often quotes the path.
SRC_EXT='\.(jl|c|h|cc|cpp|cxx|hpp|inc|S|f|f90)([":,)[:space:]]|$)'
INHERENT_RE="(share/julia/stdlib/v[0-9]+\.[0-9]+|/stdlib/[A-Za-z0-9_]+-[0-9a-f]{40}|share/julia/Compiler/|$SRC_EXT)"
# A vendored dependency compiled with --prefix=<build>/usr keeps that prefix in
# its own binary -- OpenSSL's OPENSSLDIR and ENGINESDIR are the usual ones.
# Those directories cannot exist on a device and are never consulted there, and
# the value is chosen by the dependency's build rather than by this port, so
# they are reported apart from the rest.  The distinction that matters is which
# binary holds the path: anything Julia's own images name is still a failure,
# which is where a JLL LIBPATH leak would land.
is_dep_binary() { # $1 = path of the file the hit came from
    case "${1##*/}" in
        JuliaSysimage|libjulia*) return 1 ;;
    esac
    [[ "$1" == *"/xcframeworks/"* ]]
}

FOREIGN="$(awk -F'\t' -v re="$specific_re" 're == "" || $2 !~ re' "$RAW" | sort -u)" || true
MINE="$(awk -F'\t' -v re="$specific_re" 're != "" && $2 ~ re' "$RAW")" || true
INHERENT="$(printf '%s\n' "$MINE" | awk -F'\t' -v re="$INHERENT_RE" -v roots="$roots_re" \
            'NF && ($2 ~ re || (roots != "" && $2 ~ roots))' | sort -u)" || true
REST="$(printf '%s\n' "$MINE" | awk -F'\t' -v re="$INHERENT_RE" -v roots="$roots_re" \
        'NF && $2 !~ re && (roots == "" || $2 !~ roots)' | sort -u)" || true

DEPPREFIX=""
OTHER=""
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    if is_dep_binary "${hit%%$'\t'*}"; then
        DEPPREFIX="${DEPPREFIX:+$DEPPREFIX$'\n'}$hit"
    else
        OTHER="${OTHER:+$OTHER$'\n'}$hit"
    fi
done <<< "$REST"

status=0

# Everything below writes through `head`: the full list runs to hundreds of
# lines, and a burst that size onto a non-blocking stdout -- which is what CI
# hands the script -- fails the write with EAGAIN partway through.
report() { # $1 = list, $2 = how many to show
    local n; n=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
    printf '%s\n' "$1" | head -"$2" | sed 's/^/    /'
    [[ "$n" -gt "$2" ]] && echo "    ... and $((n - $2)) more"
    echo
}

if [[ -n "$OTHER" ]]; then
    echo "FAIL: build-host paths that should not be here:"
    echo
    report "$OTHER" 20
    status=1
fi

if [[ -n "$DEPPREFIX" ]]; then
    n=$(printf '%s\n' "$DEPPREFIX" | wc -l | tr -d ' ')
    echo "NOTE: $n build-prefix strings inside vendored dependency binaries"
    echo "      (their own --prefix, unreachable and unused on a device):"
    echo
    report "$DEPPREFIX" 10
    if [[ -n "${IOS_STRICT_PATH_AUDIT:-}" ]]; then
        echo "      IOS_STRICT_PATH_AUDIT is set — treating these as failures."
        status=1
    fi
fi

if [[ -n "$FOREIGN" ]]; then
    echo "NOTE: path-shaped strings from no build tree of this machine"
    echo "      (test fixtures and docstrings, not leakage):"
    echo
    report "$FOREIGN" 5
fi

if [[ -n "$INHERENT" ]]; then
    n=$(printf '%s\n' "$INHERENT" | wc -l | tr -d ' ')
    echo "NOTE: $n baked source paths (inherent — see the header of this"
    echo "      script; fix by building from a username-free directory):"
    echo
    report "$INHERENT" 10
    if [[ -n "${IOS_STRICT_PATH_AUDIT:-}" ]]; then
        echo "      IOS_STRICT_PATH_AUDIT is set — treating these as failures."
        status=1
    fi
fi

[[ "$status" -eq 0 ]] && echo "OK: nothing outside the inherent category."
exit "$status"
