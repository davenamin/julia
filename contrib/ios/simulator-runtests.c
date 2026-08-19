// A command-line embedder that runs Julia's own test suite inside the iOS
// simulator, as a companion to contrib/ios/simulator-selftest.c.
//
// simulator-selftest.c answers "does the port come up and can interpreted
// code make a foreign call".  This answers the much broader question of
// whether the runtime, the baked sysimage and the staged stdlib tree behave
// like a Julia build when the standard test suite is pointed at them.
//
// Two drivers, selected by argv:
//
//   runtests  test/runtests.jl, upstream's own runner, unmodified.  It
//             distributes work with Distributed, so it is only usable when
//             the selection expands to a SINGLE test set: with more than one
//             it calls `addprocs_with_testenv`, which spawns
//             `Base.julia_cmd()` — and there is no julia executable on iOS.
//             Run it once per test name.  This is the fidelity check: the
//             staged tree is exercised by the runner upstream ships.
//
//   ios       contrib/ios/ios_runtests.jl, staged next to runtests.jl.  One
//             process, every test set in sequence, no Distributed and no
//             subprocesses — the only shape that could run on a device.
//
//   probe     no test file at all: a fixed diagnostic snippet, for narrowing a
//             failure that only appears in one execution mode.  It needs no
//             staged test tree, so it also works against a plain resources
//             directory.
//
// and two execution modes:
//
//   jit       leave the JIT on.  Only the simulator can do this (it runs
//             under macOS rules, where mapping executable memory is allowed),
//             so it is fast but not device-representative.
//
//   interp    --compile=min, which is what a device gets: sysimage-baked code
//             runs natively and everything else goes through the interpreter,
//             including every `ccall` (src/interpreter-ccall.c).  Much slower,
//             so keep the selection small.
//
// Build (see .github/workflows/ios.yml for the invocation CI uses):
//
//   xcrun --sdk iphonesimulator clang -arch arm64 \
//         -mios-simulator-version-min=16.4 \
//         -F <install>/Frameworks -framework Julia \
//         -Wl,-rpath,<install>/Frameworks \
//         contrib/ios/julia_ios_init.c contrib/ios/simulator-runtests.c \
//         -o runtests
//   xcrun simctl spawn booted ./runtests \
//         <install>/Frameworks <resources> <depot> ios interp goto int
//
// The resources tree must have been staged with IOS_STAGE_TESTS=1 (see
// contrib/ios/build-xcframework.sh); a shipping app has no reason to carry
// the test suite, so it is not staged by default.
//
// One thing to expect in the output either way: base/sysimg.jl bakes only
// seven stdlibs, so Test, Printf, Dates and Distributed are loaded from
// SOURCE at startup — julia_ios_init_with_paths lowers use_compiled_modules
// to EXISTING precisely so that path is taken instead of the precompiler
// spawning a julia executable the bundle does not have.  Expect a few seconds
// of that before the first test set, and considerably more under `interp`.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "julia_ios_init.h"

// Same lookup as julia_ios_init.c — see the comment there.
#if defined(__has_include)
#  if __has_include(<julia.h>)
#    include <julia.h>
#  elif __has_include(<Julia/julia/julia.h>)
#    include <Julia/julia/julia.h>
#  elif __has_include(<Julia/Julia.h>)
#    include <Julia/Julia.h>
#  else
#    error "julia.h not found - embed Julia.xcframework (its Headers are found via FRAMEWORK_SEARCH_PATHS) or add the framework's Headers/julia directory to HEADER_SEARCH_PATHS"
#  endif
#else
#  include <julia.h>
#endif

static int fail(const char *what)
{
    fprintf(stderr, "simulator-runtests: FAILED: %s\n", what);
    return 1;
}

// Print whatever Julia raised.  jl_stderr_stream() rather than the JL_STDERR
// macro: that macro names a variable libjulia-internal does not re-export
// through libjulia, which is the only library this links against.
//
// Via Julia's `showerror`, not `jl_static_show`.  static_show walks the entire
// value with no depth or length bound, so a single MethodError carrying a big
// array prints tens of thousands of `#<null>` lines and buries the message
// that actually says what went wrong — which is exactly what it did the first
// time a test run raised here.
static void report_exception(const char *what)
{
    JL_STREAM *out = jl_stderr_stream();
    jl_value_t *exc = jl_exception_occurred();
    if (exc == NULL) {
        jl_printf(out, "%s: failed without raising\n", what);
        return;
    }
    jl_printf(out, "%s: raised\n", what);

    // Root it first: jl_call replaces what jl_exception_occurred() returns.
    JL_GC_PUSH1(&exc);
    jl_function_t *showerror = jl_get_function(jl_base_module, "showerror");
    int shown = 0;
    if (showerror != NULL) {
        jl_value_t *args[2] = { jl_stderr_obj(), exc };
        jl_call(showerror, args, 2);
        shown = (jl_exception_occurred() == NULL);
        jl_printf(out, "\n");
    }
    if (!shown) {
        // showerror needs working stdio and a callable path, neither of which
        // is guaranteed when the failure was early.  The type name alone is
        // always available, and is bounded.
        jl_printf(out, "  (showerror failed) exception type: ");
        jl_static_show(out, (jl_value_t*)jl_typeof(exc));
        jl_printf(out, "\n");
    }
    JL_GC_POP();
}

// Diagnostic snippet for the `probe` driver.  Written as source and evaluated
// at runtime so it is subject to whatever execution mode was selected, which
// is the entire point: it exists to tell apart "the sysimage lacks a method"
// from "dispatch fails only in this mode" from "only the caller's context
// fails".  Each step is guarded so one failure does not hide the rest.
//
// The current subject is `sort!(::Vector{Symbol})`, which `Base.names` ends
// with, and which raised MethodError under --compile=min while the same
// sysimage under the JIT resolved it.
static const char *probe_src =
    "println(stderr, \"probe: compile_enabled = \", Base.JLOptions().compile_enabled)\n"
    "println(stderr, \"probe: world = \", Base.get_world_counter())\n"
    "try\n"
    "    println(stderr, \"probe: hasmethod(sort!, Tuple{Vector{Symbol}}) = \",\n"
    "            hasmethod(sort!, Tuple{Vector{Symbol}}))\n"
    "catch e\n"
    "    println(stderr, \"probe: hasmethod raised: \", sprint(showerror, e))\n"
    "end\n"
    "try\n"
    "    println(stderr, \"probe: which = \", which(sort!, Tuple{Vector{Symbol}}))\n"
    "catch e\n"
    "    println(stderr, \"probe: which raised: \", sprint(showerror, e))\n"
    "end\n"
    "try\n"
    "    println(stderr, \"probe: length(methods(sort!)) = \", length(methods(sort!)))\n"
    "catch e\n"
    "    println(stderr, \"probe: methods raised: \", sprint(showerror, e))\n"
    "end\n"
    "try\n"
    "    v = Symbol[:b, :a]\n"
    "    sort!(v)\n"
    "    println(stderr, \"probe: sort! ok -> \", v)\n"
    "catch e\n"
    "    println(stderr, \"probe: sort! raised: \", sprint(showerror, e))\n"
    "end\n"
    // Same sort, but bypassing the keyword entry point: if this works while
    // the plain call does not, the missing piece is the compiler-generated
    // positional method that supplies the keyword defaults, not the sort
    // itself.
    "try\n"
    "    v = Symbol[:b, :a]\n"
    "    Base.Sort.sort!(v, firstindex(v), lastindex(v),\n"
    "                    Base.Sort.DEFAULT_STABLE, Base.Order.Forward)\n"
    "    println(stderr, \"probe: positional sort! ok -> \", v)\n"
    "catch e\n"
    "    println(stderr, \"probe: positional sort! raised: \", sprint(showerror, e))\n"
    "end\n"
    "try\n"
    "    println(stderr, \"probe: defalg = \", Base.Sort.defalg(Symbol[:a]))\n"
    "catch e\n"
    "    println(stderr, \"probe: defalg raised: \", sprint(showerror, e))\n"
    "end\n"
    // Splits `names` into its two halves: the ccall that collects the symbols,
    // and the sort! that orders them.
    "try\n"
    "    println(stderr, \"probe: length(unsorted_names(Base, imported=true)) = \",\n"
    "            length(Base.unsorted_names(Base, imported=true)))\n"
    "catch e\n"
    "    println(stderr, \"probe: unsorted_names raised: \", sprint(showerror, e))\n"
    "end\n"
    "try\n"
    "    println(stderr, \"probe: length(names(Base, imported=true)) = \",\n"
    "            length(names(Base, imported=true)))\n"
    "catch e\n"
    "    println(stderr, \"probe: names raised: \", sprint(showerror, e))\n"
    "end\n"
    "try\n"
    "    Core.eval(Main, :(using Markdown))\n"
    "    println(stderr, \"probe: using Markdown ok\")\n"
    "catch e\n"
    "    println(stderr, \"probe: using Markdown raised: \", sprint(showerror, e))\n"
    "end\n"
    "nothing\n";

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s <framework-dir> <resources-dir> <writable-depot> \\\n"
            "           <runtests|ios|probe> <jit|interp> [test selection...]\n"
            "\n"
            "The test selection is passed through to test/choosetests.jl, so\n"
            "\"--skip\", \"-name\" and \"--seed=\" work as documented there.\n"
            "With the `runtests` driver it must name exactly one test set.\n"
            "The `probe` driver ignores the selection and needs no staged\n"
            "test tree; it runs a fixed diagnostic snippet.\n",
            argv0);
}

int main(int argc, char **argv)
{
    if (argc < 6) {
        usage(argv[0]);
        return 2;
    }
    const char *frameworks = argv[1];
    const char *resources  = argv[2];
    const char *depot      = argv[3];
    const char *driver     = argv[4];
    const char *mode       = argv[5];

    const char *driver_file;
    if (strcmp(driver, "runtests") == 0)
        driver_file = "runtests.jl";
    else if (strcmp(driver, "ios") == 0)
        driver_file = "ios_runtests.jl";
    else if (strcmp(driver, "probe") == 0)
        driver_file = NULL;          // no test file; see probe_src
    else {
        usage(argv[0]);
        return 2;
    }

    if (strcmp(mode, "jit") == 0)
        julia_ios_enable_jit();
    else if (strcmp(mode, "interp") == 0)
        julia_ios_set_interpreter_fallback();
    else {
        usage(argv[0]);
        return 2;
    }

    // The staged test tree, which build-xcframework.sh only produces under
    // IOS_STAGE_TESTS=1.  Check before starting the runtime so the failure
    // names its cause instead of surfacing as a Julia `SystemError`.  The
    // probe driver reads no file, so it skips this entirely.
    char script[4096];
    if (driver_file != NULL) {
        if (snprintf(script, sizeof(script), "%s/test/%s", resources, driver_file)
                >= (int)sizeof(script))
            return fail("resources path too long");
        struct stat st;
        if (stat(script, &st) != 0 || !S_ISREG(st.st_mode)) {
            fprintf(stderr,
                    "simulator-runtests: no test driver at %s\n"
                    "  Re-stage the resources with IOS_STAGE_TESTS=1.\n", script);
            return 1;
        }
    }
    else {
        snprintf(script, sizeof(script), "<built-in diagnostic snippet>");
    }

    // What test/Makefile passes on the command line.  jl_options is
    // initialized by libjulia's load-time constructor, so these stick as long
    // as they are set before jl_init.
    //
    // check_bounds only reaches codegen (src/cgutils.cpp) and the pkgimage
    // cache flags, so under `interp` it changes nothing that runs; it is set
    // in both modes anyway so the two differ only in execution mode.
    jl_options.check_bounds = JL_OPTIONS_CHECK_BOUNDS_ON;
    jl_options.depwarn      = JL_OPTIONS_DEPWARN_ERROR;
    jl_options.startupfile  = JL_OPTIONS_STARTUPFILE_OFF;

    if (julia_ios_init_with_paths(frameworks, resources, depot) != 0)
        return fail("julia_ios_init_with_paths");

    // Hand the selection to the driver.  jl_set_ARGS fills Core.ARGS; it is
    // base/client.jl's startup path that copies those into Base.ARGS, and
    // embedding does not run it, so do that copy here — test/runtests.jl
    // reads ARGS and would otherwise see an empty one and select everything.
    jl_set_ARGS(argc - 6, argv + 6);
    jl_eval_string("append!(Base.ARGS, Core.ARGS)");
    if (jl_exception_occurred()) {
        report_exception("populating Base.ARGS");
        return fail("jl_set_ARGS");
    }

    printf("simulator-runtests: %s driver, %s mode, %s\n", driver, mode, script);
    fflush(stdout);

    // Call `Base.include(Main, script)` directly rather than composing Julia
    // source around the path.  Two reasons: no quoting question about what a
    // path may contain, and no new global.  Stashing the path in a Main global
    // first is what the obvious version does, and 1.12's binding partitions
    // reject it — `jl_set_global` can only write a binding that already
    // exists, so creating one from C raises "Global Main.X does not exist and
    // cannot be assigned".
    int rc = 0;
    if (driver_file == NULL) {
        jl_eval_string(probe_src);
    }
    else {
        jl_function_t *include_fn = jl_get_function(jl_base_module, "include");
        jl_value_t *path = NULL;
        JL_GC_PUSH1(&path);
        path = jl_cstr_to_string(script);
        jl_call2(include_fn, (jl_value_t*)jl_main_module, path);
        JL_GC_POP();
    }
    if (jl_exception_occurred()) {
        // Both drivers signal a failing run by raising: runtests.jl throws
        // Test.FallbackTestSetException, and anything else escaping means the
        // driver itself broke.
        report_exception("test run");
        rc = fail("test run");
    }
    else {
        // The ios driver reports its count rather than raising, so that a
        // failing set does not hide the summary of the sets after it.
        jl_value_t *n = jl_eval_string(
            "isdefined(Main, :IOS_TEST_FAILURES) ? Main.IOS_TEST_FAILURES : 0");
        if (jl_exception_occurred() || n == NULL) {
            report_exception("reading IOS_TEST_FAILURES");
            rc = fail("reading IOS_TEST_FAILURES");
        }
        else if (jl_unbox_int64(n) != 0) {
            fprintf(stderr, "simulator-runtests: %lld test set(s) failed\n",
                    (long long)jl_unbox_int64(n));
            rc = fail("test run");
        }
    }

    julia_ios_atexit();

    if (rc == 0)
        printf("simulator-runtests: OK\n");
    return rc;
}
