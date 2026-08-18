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
static void report_exception(const char *what)
{
    JL_STREAM *out = jl_stderr_stream();
    jl_value_t *exc = jl_exception_occurred();
    if (exc == NULL) {
        jl_printf(out, "%s: failed without raising\n", what);
        return;
    }
    jl_printf(out, "%s: raised ", what);
    jl_static_show(out, exc);
    jl_printf(out, "\n");
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s <framework-dir> <resources-dir> <writable-depot> \\\n"
            "           <runtests|ios> <jit|interp> [test selection...]\n"
            "\n"
            "The test selection is passed through to test/choosetests.jl, so\n"
            "\"--skip\", \"-name\" and \"--seed=\" work as documented there.\n"
            "With the `runtests` driver it must name exactly one test set.\n",
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
    // names its cause instead of surfacing as a Julia `SystemError`.
    char script[4096];
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

    int rc = 0;
    jl_value_t *path = jl_cstr_to_string(script);
    JL_GC_PUSH1(&path);
    jl_set_global(jl_main_module, jl_symbol("IOS_TEST_SCRIPT"), path);
    JL_GC_POP();

    printf("simulator-runtests: %s driver, %s mode, %s\n", driver, mode, script);
    fflush(stdout);

    jl_eval_string("Base.include(Main, Main.IOS_TEST_SCRIPT)");
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
