// A command-line embedder for the iOS simulator, so CI can *run* the port
// instead of only compiling it.
//
// `xcrun simctl spawn` runs a plain Mach-O built for the simulator platform,
// with no app bundle and no Xcode project, which makes this the cheapest way
// to execute a real iOS-targeted libjulia + sysimage.  It calls the same
// embedding API an app would (contrib/ios/julia_ios_init.h) and exits non-zero
// on the first failure, so the CI step's status is the result.
//
// Build (see .github/workflows/ios.yml for the invocation CI uses):
//
//   xcrun --sdk iphonesimulator clang -arch arm64 \
//         -mios-simulator-version-min=16.4 \
//         -F <install>/Frameworks -framework Julia \
//         -Wl,-rpath,<install>/Frameworks \
//         contrib/ios/simulator-selftest.c -o selftest
//   xcrun simctl spawn booted ./selftest <install>/Frameworks <resources> <depot>
//
// What running here does and does not prove is worth being precise about.
// The simulator defines TARGET_OS_IPHONE, so `_OS_IOS_` is on and the
// genuinely iOS-only code paths execute: the libffi ccall interpreter
// (src/interpreter-ccall.c), the sysctl-based CPU detection and the sysimage
// target match it feeds (src/processor_arm.cpp), the framework fallback in
// dlopen (src/dlload.c), Accelerate forwarding, and every JLL path
// computation.  What it cannot show is anything whose cause is a device
// *restriction* rather than iOS code: the simulator runs under macOS rules,
// so the JIT works, `fork`/`exec` succeed, and the bundle is writable.  A
// green run here means the port loads and computes correctly; it does not
// mean the app will run on a phone.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "julia_ios_init.h"

static int fail(const char *what)
{
    fprintf(stderr, "simulator-selftest: FAILED: %s\n", what);
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
                "usage: %s <framework-dir> <resources-dir> [writable-depot]\n",
                argv[0]);
        return 2;
    }
    const char *frameworks = argv[1];
    const char *resources  = argv[2];
    const char *depot      = (argc > 3) ? argv[3] : NULL;

    // Mirrors an app launching on a device: the interpreter is the only
    // execution mode a device has, so select it here too rather than letting
    // the simulator's working JIT paper over a method the bake missed.
    julia_ios_set_interpreter_fallback();

    if (julia_ios_init_with_paths(frameworks, resources, depot) != 0)
        return fail("julia_ios_init_with_paths");

    printf("simulator-selftest: runtime initialized\n");
    fflush(stdout);

    int rc = 0;

    // Which library ended up behind each BLAS/LAPACK symbol.  Informational:
    // Accelerate is present in the simulator, but a failure to forward it is
    // a warning on device rather than a fatal error, so it is not fatal here.
    if (julia_ios_blas_report() != 0)
        fprintf(stderr, "simulator-selftest: WARNING: BLAS report raised\n");

    // The real test.  Every case is a `ccall` executed by the interpreter
    // through libffi, which is the part of this port with no equivalent
    // upstream and the part a host build cannot compile at all.  The return
    // is a failure count, or negative if the check could not run at all.
    int failures = julia_ios_ccall_selftest();
    if (failures != 0) {
        fprintf(stderr, "simulator-selftest: ccall self-test reported %d\n", failures);
        rc = fail("julia_ios_ccall_selftest");
    }

    julia_ios_atexit();

    if (rc == 0)
        printf("simulator-selftest: OK\n");
    return rc;
}
