#!/usr/bin/env bash
#
# Structural checks for the iOS port, run before a build rather than after one.
# An iOS cross-build takes about an hour, and most of what breaks it can be
# established in seconds from the tree alone.
#
#   contrib/ios/ci-checks.sh            # everything, including patch checks
#   contrib/ios/ci-checks.sh --offline  # skip the checks that fetch sources
#
# What is checked, and why each needs checking here:
#
#   Fork-local patches.  Each is pinned to one upstream revision, and the only
#   way to know it still applies is to fetch that revision and try.
#
#   iOS-only code.  Regions behind `#if defined(_OS_IOS_)`, and everything in
#   contrib/ios/, are compiled by no other build; a renamed runtime API there
#   survives a rebase without a conflict.  Both are compiled here.
#
#   Fork-local copies of upstream constructs.  The iOS build spells out by
#   hand what the ordinary build computes -- link archives, rule prerequisites
#   -- and those copies are compared against the originals.
#
# Set IOS_CHECKS_REQUIRE_COMPILE=1 where the compile checks are known to be
# supported, so an environment that loses the ability to run them fails rather
# than skipping quietly.  The iOS SDK is never needed.

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

# julia-sysimg-ios-% is a fork-local copy of upstream's julia-sysimg-%, so a
# prerequisite added to the original will not appear in the copy.  Each stands
# for something the bake reads: TOP_LEVEL_PKG_LINK_TARGETS, for instance,
# makes the usr/share/julia/Compiler symlink that Base_compiler.jl includes by
# path.  julia-cli-% is exempt -- julia-src-% requires it already.
sysimg_prereqs() {
    sed -nE "s/^julia-sysimg-$1(release|-release) .*: julia-sysimg-$1% : (.*)/\2/p" Makefile \
        | head -1 | sed 's/|.*//'
}
generic=$(sysimg_prereqs "")
iosreq=$(sysimg_prereqs "ios-")
drift=""
for p in $generic; do
    [[ "$p" == "julia-cli-%" ]] && continue
    grep -qF -- "$p" <<<"$iosreq" || drift="$drift $p"
done
if [[ -z "$generic" || -z "$iosreq" ]]; then
    fail "could not read the julia-sysimg prerequisites from Makefile"
elif [[ -z "$drift" ]]; then
    pass "julia-sysimg-ios-% carries every prerequisite julia-sysimg-% has"
else
    fail "julia-sysimg-ios-% is missing prerequisites:$drift"
fi

# The iOS branch of src/Makefile spells RT_LLVMLINK out by hand, because
# llvm-config is built for iOS and cannot run on the host to be asked.  That
# hand-written list must cover the same archives as RT_LLVM_LIBS, which the
# ordinary path passes to llvm-config; an archive missing from it is a link
# error against libjulia-internal.
rt_libs=$(sed -nE 's/^RT_LLVM_LIBS[[:space:]]*:?=[[:space:]]*(.*)/\1/p' src/Makefile | head -1)
ios_link=$(sed -n '/^ifeq ($(IOS), 1)/,/^endif # IOS/p' src/Makefile | grep -E '^RT_LLVMLINK')
missing=""
for lib in $rt_libs; do
    # `support` names libLLVMSupport, `targetparser` libLLVMTargetParser.
    grep -qiE -- "-lLLVM$lib([^A-Za-z]|$)" <<<"$ios_link" || missing="$missing $lib"
done
if [[ -z "$rt_libs" ]]; then
    fail "could not read RT_LLVM_LIBS from src/Makefile"
elif [[ -z "$missing" ]]; then
    pass "the iOS RT_LLVMLINK covers every RT_LLVM_LIBS archive ($rt_libs)"
else
    fail "the iOS RT_LLVMLINK is missing:$missing"
fi

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

# A `goto` whose label does not exist in the same file.  This catches an
# iOS-only block written against one release's version of a function and
# merged onto another's without conflict, since it sits in a region only this
# fork has.  Labels may be written `name:` or `name :`.
goto_bad=$(python3 - <<'GOTOPY' 2>&1
import re, glob
bad = []
for f in sorted(glob.glob("src/*.c") + glob.glob("src/*.cpp")):
    s = open(f, errors="ignore").read()
    labels = set(re.findall(r'^\s*([A-Za-z_]\w*)\s*:(?!:)', s, re.M))
    for m in re.finditer(r'\bgoto\s+([A-Za-z_]\w*)\s*;', s):
        if m.group(1) not in labels:
            bad.append("      %s: goto %s has no label in this file" % (f, m.group(1)))
print("\n".join(sorted(set(bad))))
GOTOPY
)
if [[ -z "$goto_bad" ]]; then
    pass "every goto in src/ resolves to a label in the same file"
else
    fail "a goto names a label that does not exist"
    printf '%s\n' "$goto_bad"
fi

# Runtime API names used only from iOS-only code.  Code inside `#if
# defined(_OS_IOS_)` is compiled by no other build, so a name the runtime has
# renamed since survives a rebase without a conflict.  Every jl_/JL_ name
# reached from such a region is resolved against the headers.
api_bad=$(python3 - <<'APIPY' 2>&1
import re, glob

def strip_comments(s):
    # Blank out comments and string literals, keeping line structure so the
    # preprocessor scan below still sees the right lines.
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\\n])*"', blank, s, flags=re.S)

declared = set()
for h in glob.glob("src/*.h") + glob.glob("src/support/*.h"):
    declared.update(re.findall(r"\b(?:jl|JL)_\w+", open(h, errors="ignore").read()))
# The exported globals (jl_nothing_type and the like) are not spelled out in
# any header: src/Makefile generates a `#define jl_<name>` for each entry of
# this list.
for name in re.findall(r"\b(?:XX|YY)\((\w+),", open("src/jl_exported_data.inc").read()):
    declared.add("jl_" + name)

IOS_COND = re.compile(r"_OS_IOS_|JL_CCALL_FFI")
NEGATED = re.compile(r"!\s*(?:defined\s*\(\s*)?(?:_OS_IOS_|JL_CCALL_FFI)")

bad = []
for f in sorted(glob.glob("src/*.c") + glob.glob("src/*.cpp")):
    src = strip_comments(open(f, errors="ignore").read())
    if not IOS_COND.search(src):
        continue
    # Names this file defines itself: macros, file-scope functions, typedefs.
    local = set(re.findall(r"^\s*#\s*define\s+(\w+)", src, re.M))
    local.update(re.findall(r"^\}\s*(\w+);", src, re.M))
    local.update(re.findall(r"^\s*static\s+[^;()]*?\b(\w+)\s*\(", src, re.M))
    local.update(re.findall(r"^\w[\w \t\*]*?\b(\w+)\s*\([^;]*$", src, re.M))

    # One frame per open #if, as (condition names iOS, this branch is iOS-only).
    # The first is kept so that `#else` can invert -- the body guarded by
    # `#if !JL_CCALL_FFI ... #else` is the iOS one.
    def branch(kw, rest):
        names = bool(IOS_COND.search(rest))
        negated = bool(NEGATED.search(rest)) or kw == "ifndef"
        return names, names and not negated

    stack = []
    for n, line in enumerate(src.split("\n"), 1):
        d = re.match(r"\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)", line)
        if d:
            kw, rest = d.group(1), d.group(2)
            if kw in ("if", "ifdef", "ifndef"):
                stack.append(branch(kw, rest))
            elif kw == "elif" and stack:
                stack[-1] = branch(kw, rest)
            elif kw == "else" and stack:
                names, is_ios = stack[-1]
                stack[-1] = (names, names and not is_ios)
            elif kw == "endif" and stack:
                stack.pop()
            continue
        if not any(is_ios for _, is_ios in stack):
            continue
        for name in re.findall(r"\b(?:jl|JL)_\w+", line):
            if name not in declared and name not in local:
                bad.append("      %s:%d: %s is not declared in any src header" % (f, n, name))
print("\n".join(sorted(set(bad))))
APIPY
)
if [[ -z "$api_bad" ]]; then
    pass "every jl_/JL_ name used from iOS-only code resolves in the headers"
else
    fail "iOS-only code names a runtime API that does not exist"
    printf '%s\n' "$api_bad"
fi

# Type-check the same regions for real, which also catches wrong argument
# counts and wrong types.  `_OS_IOS_` is reachable only on Apple platforms --
# support/platform.h defines it inside the Darwin branch -- but defining it
# directly compiles the iOS regions anywhere: the three headers a build would
# generate are stubbed, and no iOS SDK is involved.
#
# Each file is compiled twice.  A src/ file that fails even without
# `_OS_IOS_` is one this environment cannot build at all -- processor_arm.cpp
# wants an ARM host, jitlayers.cpp a matching LLVM -- and is skipped rather
# than blamed.
FFI_INC=""
if [[ -f /usr/include/ffi.h ]]; then
    FFI_INC="/usr/include"
elif ffi_dir=$(pkg-config --variable=includedir libffi 2>/dev/null) && [[ -f "$ffi_dir/ffi.h" ]]; then
    FFI_INC="$ffi_dir"
elif sdk=$(xcrun --show-sdk-path 2>/dev/null) && [[ -f "$sdk/usr/include/ffi/ffi.h" ]]; then
    FFI_INC="$sdk/usr/include/ffi"
else
    for d in /usr/include/*-linux-gnu; do
        [[ -f "$d/ffi.h" ]] && FFI_INC="$d" && break
    done
fi

if ! command -v cc >/dev/null 2>&1 || ! command -v llvm-config >/dev/null 2>&1; then
    skip "iOS-only code compile check (needs cc and llvm-config)"
elif [[ -z "$FFI_INC" ]]; then
    skip "iOS-only code compile check (no ffi.h; install libffi-dev)"
else
    gendir=$(mktemp -d)
    trap 'rm -rf "$gendir"' EXIT
    # The headers the build generates, made the way src/Makefile makes them.
    v=$(cat VERSION)
    { echo "#ifndef JL_VERSION_H"; echo "#define JL_VERSION_H"
      echo "#define JULIA_VERSION_STRING \"$v\""
      echo "$v" | awk 'BEGIN{FS="[.,+-]"}{print "#define JULIA_VERSION_MAJOR "$1"\n#define JULIA_VERSION_MINOR "$2"\n#define JULIA_VERSION_PATCH "$3;
                       print (NF<4) ? "#define JULIA_VERSION_IS_RELEASE 1" : "#define JULIA_VERSION_IS_RELEASE 0"}'
      echo "#endif"; } > "$gendir/julia_version.h"
    grep 'XX(..*)' src/jl_exported_funcs.inc \
        | sed -E 's/.*XX\((.+)\).*/#define \1 i\1/g' > "$gendir/jl_internal_funcs.inc"
    { grep 'XX(.*)' src/jl_exported_data.inc \
          | sed -E 's/.*XX\(([^,]+), .*\).*/#define jl_\1 (sysimg_global.\1)/g'
      grep 'YY(.*)' src/jl_exported_data.inc \
          | sed -E 's/.*YY\(([^,]+), .*\).*/#define jl_\1 (const_globals.jl\1)/g'
    } > "$gendir/jl_data_globals_defs.inc"
    : > "$gendir/uprobes.h.gen"

    # clang makes an implicit declaration an error and gcc only warns, so ask
    # for the error: a renamed function is otherwise just a warning here.
    cc_werror="-Werror=implicit-function-declaration -Werror=implicit-int"
    cc_werror="$cc_werror -Werror=incompatible-pointer-types -Werror=int-conversion"
    cc_inc="-D_GNU_SOURCE -I src -I src/support -I src/flisp -I contrib/ios -I $gendir"
    cc_inc="$cc_inc -I $(llvm-config --includedir) -I $FFI_INC"

    # contrib/ios/*.c comes along unconditionally: the embedding helper and
    # the simulator harness are compiled by an app target and by the simulator
    # job and by nothing else, the same position the `_OS_IOS_` regions are in.
    judged=0
    # `jl_foreigncall_interpretable` catches the files that take part in the
    # interpreted-ccall path without carrying an iOS macro themselves --
    # src/interpreter.c and src/toplevel.c.  Both are edited by this fork, and
    # neither was covered while the pattern only looked for _OS_IOS_.
    for f in $(grep -lE '_OS_IOS_|JL_CCALL_FFI|jl_foreigncall_interpretable' src/*.c src/*.cpp 2>/dev/null) \
             contrib/ios/*.c; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *.cpp) comp="${CXX:-c++} -std=c++17" ;;
            *)     comp="${CC:-cc}" ;;
        esac
        # shellcheck disable=SC2086
        if ! base=$($comp -fsyntax-only $cc_werror $cc_inc "$f" 2>&1); then
            # Name the cause: a skip that does not is indistinguishable from
            # a pass, and one missing header can skip every file at once.
            why=$(printf '%s\n' "$base" | awk '/error:/{sub(/.*error: /, ""); print; exit}')
            # contrib/ios/ is portable C, so it has no claim on the skip above
            # -- a baseline failure there is the defect itself.
            case "$f" in
                contrib/ios/*)
                    fail "$f does not compile: ${why:-unknown}"
                    printf '%s\n' "$base" | grep -m 5 -E "error:" | sed 's/^/      /'
                    continue ;;
            esac
            skip "$f (does not compile here without _OS_IOS_ either: ${why:-unknown})"
            continue
        fi
        judged=$((judged + 1))
        # shellcheck disable=SC2086
        if out=$($comp -fsyntax-only -D_OS_IOS_ $cc_werror $cc_inc "$f" 2>&1); then
            pass "$f compiles with _OS_IOS_"
        else
            fail "$f does not compile with _OS_IOS_"
            printf '%s\n' "$out" | grep -m 10 -E "error:" | sed 's/^/      /'
        fi
    done
    # A run where every file skipped checked nothing, which is the one outcome
    # that must not look like a pass.  CI sets this to say the environment is
    # supposed to support the check, so a regression in it is a failure rather
    # than a quiet skip; elsewhere the skips above are explanation enough.
    if [[ "$judged" == 0 && -n "${IOS_CHECKS_REQUIRE_COMPILE:-}" ]]; then
        fail "no file could be compiled, so the iOS-only code went unchecked"
    fi
    rm -rf "$gendir"
    trap - EXIT
fi

# App Store validation rejects a binary that references private symbols, so
# on iOS signals-mach.c must not declare the keymgr and dyld-atfork functions
# at all: it defines no-op stand-ins in the `#ifdef _OS_IOS_` branch and keeps
# the real `extern` declarations in the `#else`.
unguarded=$(python3 - <<'PY'
import re
private = re.compile(r"\bextern\b.*\b(_dyld_(dlopen_)?atfork\w*|_keymgr_\w+)")
stack = []   # one entry per open #if: True while inside the non-iOS branch of an _OS_IOS_ test
bad = []
for n, l in enumerate(open("src/signals-mach.c"), 1):
    d = re.match(r"\s*#\s*(ifdef|ifndef|if|else|endif)\b(.*)", l)
    if d:
        kw, rest = d.groups()
        if kw in ("if", "ifdef", "ifndef"):
            stack.append(kw == "ifndef" and "_OS_IOS_" in rest)
            stack[-1] = [stack[-1], "_OS_IOS_" in rest]
        elif kw == "else" and stack and stack[-1][1]:
            stack[-1][0] = not stack[-1][0]
        elif kw == "endif" and stack:
            stack.pop()
        continue
    if private.search(l) and not l.strip().startswith("//") \
            and not any(non_ios for non_ios, _ in stack):
        bad.append(f"{n}: {l.rstrip()}")
print("\n".join(bad))
PY
)
if [[ -z "$unguarded" ]]; then
    pass "signals-mach.c declares no private dyld/keymgr API on iOS"
else
    fail "signals-mach.c declares private API where an iOS build can see it"
    echo "$unguarded"
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

# The tier steps name test sets for test/choosetests.jl, which errors on a
# name it cannot resolve.  A typo there costs a full dependency build, a
# sysimage bake and a simulator boot before it surfaces.
import os
def step_env(s):
    return s.get("env") or {}
for name, job in jobs.items():
    for s in job["steps"]:
        for key in ("TIER1_TESTS", "TIER2_TESTS"):
            for t in str(step_env(s).get(key, "")).split():
                if not os.path.isfile(os.path.join("test", t + ".jl")):
                    bad.append("%s: %s names %r but test/%s.jl does not exist"
                               % (name, key, t, t))

# Those steps read the test tree out of the staged resources, which
# build-xcframework.sh only produces under IOS_STAGE_TESTS=1.
runs_tiers = any(k in step_env(s)
                 for job in jobs.values() for s in job["steps"]
                 for k in ("TIER1_TESTS", "TIER2_TESTS"))
stages = any(str(step_env(s).get("IOS_STAGE_TESTS", "")) == "1"
             for job in jobs.values() for s in job["steps"])
if runs_tiers and not stages:
    bad.append("a tier step runs the test suite but no step sets IOS_STAGE_TESTS=1")

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

# Every step script is bash (the workflow sets `defaults.run.shell: bash`), and
# a syntax error in one is only discovered by spending a runner on it.
if command -v python3 >/dev/null 2>&1 &&
   python3 -c 'import yaml' >/dev/null 2>&1; then
    stepdir=$(mktemp -d)
    python3 - "$stepdir" <<'STEPPY'
import sys, os, yaml
out = sys.argv[1]
d = yaml.safe_load(open(".github/workflows/ios.yml"))
for jname, job in d["jobs"].items():
    for i, s in enumerate(job["steps"]):
        run = s.get("run")
        if not run:
            continue
        name = "%s-%02d-%s" % (jname, i, (s.get("name") or "unnamed"))
        name = "".join(c if c.isalnum() or c in "-_" else "_" for c in name)
        open(os.path.join(out, name + ".sh"), "w").write(run)
STEPPY
    bad=0
    for f in "$stepdir"/*.sh; do
        [[ -f "$f" ]] || continue
        if ! err=$(bash -n "$f" 2>&1); then
            fail "workflow step $(basename "$f" .sh) is not valid bash"
            printf '%s\n' "$err" | sed 's/^/      /'
            bad=1
        fi
    done
    [[ "$bad" -eq 0 ]] && pass "every ios.yml run: block parses as bash ($(ls "$stepdir" | wc -l | tr -d ' ') steps)"
    rm -rf "$stepdir"
else
    skip "workflow step shell syntax (needs python3 + pyyaml)"
fi

# Bindings are partitioned by world age, and `jl_set_global` can only write one
# that already exists -- creating a Main global from C raises "Global Main.X does
# not exist and cannot be assigned" at runtime, with nothing at compile time
# to say so.  Pass the value as a call argument instead (jl_call2 and friends).
if out=$(grep -n "jl_set_global[[:space:]]*([[:space:]]*jl_main_module" contrib/ios/*.c 2>/dev/null); then
    fail "jl_set_global cannot create a Main global"
    printf '%s\n' "$out" | sed 's/^/      /'
else
    pass "no C code creates a Main global with jl_set_global"
fi

# The test-suite harness resolves its driver by filename inside the staged
# resources tree.  Nothing links the two, so check the names agree: a driver
# the stager never copies fails only at the point of running it.
for drv in $(sed -n 's/.*driver_file = "\([A-Za-z0-9_.-]*\)".*/\1/p' \
                 contrib/ios/simulator-runtests.c 2>/dev/null); do
    if [[ -f "test/$drv" ]]; then
        pass "simulator-runtests.c driver test/$drv exists in the source tree"
    elif [[ -f "contrib/ios/$drv" ]] &&
         grep -q "ios_runtests.jl" contrib/ios/build-xcframework.sh; then
        pass "simulator-runtests.c driver $drv is staged from contrib/ios/"
    else
        fail "simulator-runtests.c names driver '$drv' that nothing provides at <resources>/test/$drv"
    fi
done

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

# `llvm-ios-no-z-defs` (deps/tools/common.mk) is a sed over
# HandleLLVMOptions.cmake rather than a patch, applied to two llvm-project
# checkouts at different versions.  It fails the build if its anchor is gone;
# find that out here instead.
if [[ "$OFFLINE" == 1 ]]; then
    skip "llvm-ios-no-z-defs anchor (--offline)"
else
    for spec in "JuliaLang/llvm-project|$(version_var deps/llvm.version LLVM_BRANCH)" \
                "llvm/llvm-project|llvmorg-$(version_var deps/llvmunwind.version LLVMUNWIND_VER)"; do
        IFS='|' read -r repo ref <<< "$spec"
        n=$(curl -fsSL --retry 3 --max-time 120 \
                "https://raw.githubusercontent.com/$repo/$ref/llvm/cmake/modules/HandleLLVMOptions.cmake" \
            | grep -c 'MATCHES "Darwin|')
        if [[ "$n" == 1 ]]; then
            pass "llvm-ios-no-z-defs finds its anchor in $repo@$ref"
        else
            fail "llvm-ios-no-z-defs expects one 'MATCHES \"Darwin|' in $repo@$ref, found ${n:-none}"
        fi
    done
fi

# ---------------------------------------------------------------------------
section "sysimage-ios.mk"

# Only parseable where Make.inc's iOS SDK probe succeeds, i.e. on a macOS host
# with Xcode.  Everywhere else this is a no-op rather than a false failure.
if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    builddir=$(mktemp -d)

    # stdlib.mk makes every stdlib's installed Project.toml a prerequisite of
    # sysbase.ji.  A real build has them by then -- the top-level Makefile
    # makes julia-sysimg-ios-% wait on julia-stdlib -- but this check builds
    # nothing, so stub the install tree or make stops at the first missing
    # one and never expands stages 2-4.  Only the paths matter; `make -n`
    # does not read them.
    versdir="v$(cut -d. -f1-2 < VERSION)"
    for name in $(ls -d stdlib/*/ 2>/dev/null | xargs -n1 basename) \
                $(ls stdlib/*.version 2>/dev/null | xargs -n1 basename | sed 's/\.version$//'); do
        mkdir -p "$builddir/usr/share/julia/stdlib/$versdir/$name/src"
        : > "$builddir/usr/share/julia/stdlib/$versdir/$name/Project.toml"
    done

    # The stubs above satisfy the Project.toml prerequisites; the src/ dirs
    # are empty, so stdlib.mk's `find` still says nothing to report.
    noise='^[[:space:]]*find: .*No such file or directory$'
    if out=$(make -f sysimage-ios.mk -n sysimg-ios-release \
                  BUILDROOT="$builddir" IOS=1 2>&1); then
        stages=$(grep -c -- '--output-ji\|--output-o' <<< "$out")
        if [[ "$stages" -ge 3 ]]; then
            pass "sysimage-ios.mk expands all bake stages ($stages julia invocations)"
        else
            fail "sysimage-ios.mk expanded only $stages bake stages, expected 3"
            grep -vE "$noise" <<< "$out" | tail -40 | sed 's/^/      /'
        fi
    else
        fail "sysimage-ios.mk does not expand"
        grep -vE "$noise" <<< "$out" | tail -40 | sed 's/^/      /'
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
