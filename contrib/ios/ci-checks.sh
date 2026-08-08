#!/usr/bin/env bash
#
# Fast structural checks for the iOS port.  No compiler, no Xcode, no Julia --
# everything here runs in a couple of minutes on any machine with bash, git,
# curl and patch, which is what makes it worth running before a build rather
# than after one.
#
#   contrib/ios/ci-checks.sh            # everything that works offline + patches
#   contrib/ios/ci-checks.sh --offline  # skip the checks that fetch sources
#
# The patch checks are the reason this exists.  A fork-local patch is pinned to
# one upstream revision, and the only way to know it still applies is to fetch
# that revision and try.  A dependency bump that silently invalidates a patch
# otherwise surfaces an hour into a build.

set -uo pipefail

JULIAHOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$JULIAHOME"

OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1

FAILED=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
skip() { printf '  --    %s (skipped)\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# Read `NAME = value` or `NAME := value` out of a .version file.
version_var() {
    sed -nE "s/^[[:space:]]*$2[[:space:]]*:?=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$1" | head -1
}

# ---------------------------------------------------------------------------
section "working tree"

if git grep -qIn -e '^<<<<<<< ' -e '^>>>>>>> ' -- . 2>/dev/null; then
    fail "conflict markers in tracked files"
    git grep -In -e '^<<<<<<< ' -e '^>>>>>>> ' -- . | head
else
    pass "no conflict markers"
fi

# ---------------------------------------------------------------------------
section "shell scripts"

for s in contrib/ios/*.sh deps/tools/objconv-fix-alignment.sh; do
    [[ -f "$s" ]] || continue
    if bash -n "$s" 2>/dev/null; then pass "$s parses"; else fail "$s has a syntax error"; bash -n "$s"; fi
done

# ---------------------------------------------------------------------------
section "jl_options layout"

# base/options.jl mirrors the C struct field-for-field and Julia reads it by
# offset, so a field added to one and not the other corrupts every option.
c_fields=$(sed -n '/^typedef struct {/,/} jl_options_t;/p' src/jloptions.h \
           | grep -cE '^\s+[A-Za-z_].*;')
jl_fields=$(sed -n '/^struct JLOptions/,/^end/p' base/options.jl \
            | grep -cE '^\s+[a-z_0-9]+::')
if [[ "$c_fields" == "$jl_fields" ]]; then
    pass "JLOptions field count matches jl_options_t ($c_fields)"
else
    fail "JLOptions has $jl_fields fields, jl_options_t has $c_fields"
fi

# ---------------------------------------------------------------------------
section "iOS wiring"

grep -q 'interpreter-ccall' src/Makefile \
    && pass "interpreter-ccall is in src/Makefile SRCS" \
    || fail "interpreter-ccall missing from src/Makefile SRCS"

# libffi has to be in DEP_LIBS (so it builds) *and* DEP_LIBS_STAGED_ALL (so
# `version-check-libffi` and the uninstall rules exist); missing the second
# fails the build with "No rule to make target 'version-check-libffi'".
# DEP_LIBS_STAGED_ALL is a backslash-continued list, so match it as one string.
staged_all=$(sed -nE '/^DEP_LIBS_STAGED_ALL[[:space:]]*:?=/,/[^\\]$/p' deps/Makefile | tr -d '\\\n')
if grep -qE '^DEP_LIBS \+= libffi' deps/Makefile && [[ "$staged_all" == *libffi* ]]; then
    pass "libffi is in both DEP_LIBS and DEP_LIBS_STAGED_ALL"
else
    fail "libffi missing from DEP_LIBS or DEP_LIBS_STAGED_ALL in deps/Makefile"
fi

# App Store validation rejects a binary that references private symbols, so
# every keymgr/dyld-atfork call has to sit inside a !TARGET_OS_IPHONE guard.
unguarded=$(python3 - <<'PY'
import re
depth = 0
bad = []
for n, l in enumerate(open("src/signals-mach.c"), 1):
    if re.match(r"\s*#if\s*!TARGET_OS_IPHONE", l):
        depth += 1
    elif re.match(r"\s*#if", l) and depth:
        depth += 1
    elif re.match(r"\s*#endif", l) and depth:
        depth -= 1
    if not depth and re.search(r"_dyld_(dlopen_)?atfork|_keymgr_", l) \
            and not l.strip().startswith("//"):
        bad.append(f"{n}: {l.rstrip()}")
print("\n".join(bad))
PY
)
if [[ -z "$unguarded" ]]; then
    pass "signals-mach.c references no private dyld/keymgr API outside a guard"
else
    fail "signals-mach.c has unguarded private-API references"
    echo "$unguarded"
fi

# The simulator harness is compiled by CI against the framework, which needs
# macOS; a syntax-only pass catches the ordinary mistakes anywhere.
if command -v cc >/dev/null 2>&1; then
    if out=$(cc -fsyntax-only -Wall -I contrib/ios contrib/ios/simulator-selftest.c 2>&1); then
        pass "contrib/ios/simulator-selftest.c compiles"
    else
        fail "contrib/ios/simulator-selftest.c does not compile"
        echo "$out" | sed 's/^/      /'
    fi
else
    skip "simulator-selftest.c syntax check (no cc)"
fi

# ---------------------------------------------------------------------------
section "workflow"

if [[ -f .github/workflows/ios.yml ]] && command -v python3 >/dev/null 2>&1; then
    out=$(python3 - <<'WFPY' 2>&1
import sys
try:
    import yaml
except ImportError:
    print("SKIP: no pyyaml"); sys.exit(0)
d = yaml.safe_load(open(".github/workflows/ios.yml"))
jobs = d["jobs"]
bad = []
for name, job in jobs.items():
    needs = job.get("needs", [])
    for n in ([needs] if isinstance(needs, str) else needs):
        if n not in jobs:
            bad.append("%s needs unknown job %r" % (name, n))
# Every artifact downloaded must be uploaded by some job, or the consumer
# blocks forever waiting for something nothing produces.
produced = set()
for job in jobs.values():
    for s in job["steps"]:
        if str(s.get("uses", "")).startswith("actions/upload-artifact"):
            produced.add(s.get("with", {}).get("name"))
for name, job in jobs.items():
    for s in job["steps"]:
        if str(s.get("uses", "")).startswith("actions/download-artifact"):
            a = s.get("with", {}).get("name")
            if a not in produced:
                bad.append("%s downloads artifact %r that nothing uploads" % (name, a))
print("\n".join(bad))
WFPY
)
    if [[ -z "$out" ]]; then
        pass ".github/workflows/ios.yml parses; job and artifact wiring resolves"
    elif [[ "$out" == SKIP:* ]]; then
        skip ".github/workflows/ios.yml checks (${out#SKIP: })"
    else
        fail ".github/workflows/ios.yml is inconsistent"
        echo "$out" | sed 's/^/      /'
    fi
else
    skip "workflow checks"
fi

# ---------------------------------------------------------------------------
section "fork-local patches apply to their pinned sources"

if [[ "$OFFLINE" == 1 ]]; then
    skip "patch application (--offline)"
else
    LLVM_REF=$(version_var deps/llvm.version LLVM_BRANCH)
    LLVMUNWIND_VER=$(version_var deps/llvmunwind.version LLVMUNWIND_VER)
    PKG_REF=$(version_var stdlib/Pkg.version PKG_SHA1)
    LA_REF=$(version_var stdlib/LinearAlgebra.version LINEARALGEBRA_SHA1)

    # patch | upstream repo | ref | strip level.  Paths inside each patch are
    # repo-relative; the strip level is how many leading components the
    # makefile rule that applies it has already `cd`'d past.
    PATCHES=(
      "deps/patches/llvm-ios-no-z-defs.patch|JuliaLang/llvm-project|$LLVM_REF|1"
      "deps/patches/llvm-ios-sancov-libcxx-string-init.patch|JuliaLang/llvm-project|$LLVM_REF|1"
      "deps/patches/llvm-libunwind-ios-public-dyld-api.patch|llvm/llvm-project|llvmorg-$LLVMUNWIND_VER|2"
      "stdlib/patches/Pkg-spawn-free-gzip.patch|JuliaLang/Pkg.jl|$PKG_REF|1"
      "stdlib/patches/LinearAlgebra-ios-accelerate.patch|JuliaLang/LinearAlgebra.jl|$LA_REF|1"
    )

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    for entry in "${PATCHES[@]}"; do
        IFS='|' read -r patch repo ref strip <<< "$entry"
        name=$(basename "$patch")
        if [[ ! -f "$patch" ]]; then fail "$name: missing"; continue; fi
        if [[ -z "$ref" ]]; then fail "$name: could not read the pinned ref"; continue; fi

        root="$workdir/$name"
        # `+++ b/<path>` after `patch -p<strip>` is the path relative to the
        # directory the patch is applied from; rebuild just that much of the
        # tree from raw.githubusercontent.com rather than cloning.
        ok=1
        while read -r upstream; do
            # `patch -pN` drops N leading components including the `b/` the
            # sed below already removed, so N-1 remain to drop here.
            rel=$(echo "$upstream" | cut -d/ -f"$strip"-)
            mkdir -p "$root/$(dirname "$rel")"
            if ! curl -fsSL --retry 3 --max-time 120 \
                    "https://raw.githubusercontent.com/$repo/$ref/$upstream" \
                    -o "$root/$rel"; then
                fail "$name: could not fetch $repo@$ref:$upstream"
                ok=0
                break
            fi
        done < <(grep -E '^\+\+\+ b/' "$patch" | sed 's|^+++ b/||')
        [[ "$ok" == 1 ]] || continue

        if out=$(cd "$root" && patch "-p$strip" --dry-run -f < "$JULIAHOME/$patch" 2>&1); then
            if echo "$out" | grep -q "fuzz"; then
                fail "$name: applies only with fuzz -- re-anchor it against $ref"
                echo "$out" | sed 's/^/      /'
            else
                pass "$name applies to $repo@${ref:0:12}"
            fi
        else
            fail "$name does not apply to $repo@${ref:0:12}"
            echo "$out" | sed 's/^/      /'
        fi
    done
fi

# ---------------------------------------------------------------------------
section "sysimage-ios.mk"

# Only parseable where Make.inc's iOS SDK probe succeeds, i.e. on a macOS host
# with Xcode.  Everywhere else this is a no-op rather than a false failure.
if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    builddir=$(mktemp -d)
    if out=$(make -f sysimage-ios.mk -n sysimg-ios-release \
                  BUILDROOT="$builddir" IOS=1 2>&1); then
        stages=$(grep -c -- '--output-ji\|--output-o' <<< "$out")
        if [[ "$stages" -ge 3 ]]; then
            pass "sysimage-ios.mk expands all bake stages ($stages julia invocations)"
        else
            fail "sysimage-ios.mk expanded only $stages bake stages, expected 3"
            echo "$out" | sed 's/^/      /' | head -40
        fi
    else
        fail "sysimage-ios.mk does not expand"
        echo "$out" | sed 's/^/      /' | head -40
    fi
    rm -rf "$builddir"
else
    skip "sysimage-ios.mk expansion (needs macOS + iOS SDK)"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAILED" == 0 ]]; then
    printf '\033[32mall checks passed\033[0m\n'
else
    printf '\033[31msome checks failed\033[0m\n'
fi
exit "$FAILED"
