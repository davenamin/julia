// julia_ios_init.h — helper for embedding the Julia.framework / .xcframework
// into an iOS app.
//
// The framework ships libjulia.dylib, libjulia-internal.dylib, sys.dylib, and
// a handful of dependency dylibs.  The iOS app additionally needs to ship the
// "runtime resources" tree produced by contrib/ios/build-xcframework.sh
// (julia-runtime-resources/) so Julia can locate its stdlib + any packages
// baked into the sysimage.
//
// The functions below wire up the paths and call jl_init_with_image with
// the framework-relative sys.dylib path, before Julia is asked to do
// anything else.
//
// Usage (Swift app, after Embed & Sign of Julia.framework):
//
//   guard let fwUrl = Bundle.main.privateFrameworksURL?
//           .appendingPathComponent("Julia.framework"),
//         let resUrl = Bundle.main.url(forResource: "julia-runtime-resources",
//                                      withExtension: nil)
//   else { fatalError("Julia.framework or resources not in bundle") }
//   julia_ios_init_with_paths(fwUrl.path, resUrl.path)
//   // ... jl_eval_string("..."), call into Julia ...
//   julia_ios_atexit()

#ifndef JULIA_IOS_INIT_H
#define JULIA_IOS_INIT_H

#ifdef __cplusplus
extern "C" {
#endif

// Set the Julia path env vars so all of Julia's path-relative lookups
// resolve into the shipped resources tree.  Safe to call before jl_init();
// no-op if resources_path is NULL.
//
//   resources_path: absolute path to the julia-runtime-resources directory
//                   shipped in the app bundle.
//
// Sets JULIA_BINDIR=<resources>/bin (so Sys.STDLIB, the CA cert path, and
// Pkg's stdlib directory — all computed as BINDIR/../share/julia/... —
// land in the shipped tree), plus JULIA_DEPOT_PATH / JULIA_PROJECT /
// JULIA_LOAD_PATH.  Note BINDIR does NOT point at the framework: sys.dylib
// and the dependency dylibs load via dyld @rpath, not relative to BINDIR.
void julia_ios_set_paths(const char *resources_path);

// NOTE: the framework_path argument is validated but used only as a
// fallback for locating sys.dylib — sys.dylib is opened from the framework
// directory dyld actually loaded libjulia from (found via dladdr), which
// may differ from the embedded copy (e.g. simulator Debug builds resolve
// the app's framework link against DerivedData/Build/Products).  Mixing
// the two loads a second set of Julia dylibs and fails jl_init's sysimage
// consistency check.
//
// Combines julia_ios_set_paths + jl_init_with_image into one call: it
// points JULIA_BINDIR at <resources>/bin, opens the framework's sys.dylib,
// and calls jl_init_with_image.  No post-init patching is needed — Base
// computes Sys.STDLIB (and Pkg its stdlib dir) from BINDIR, which now
// resolves into the resources tree.  Returns 0 on success, -1 on failure
// (framework_path or resources_path missing/not a directory, or an
// exception during jl_init).
//
// THREADING: the thread this runs on becomes Julia's main thread — all
// later jl_eval_string / jl_call* invocations must happen on that same
// thread (or via Julia-side threading primitives).  Initializing on a
// dispatch queue and then calling into Julia from the UI thread is
// undefined behavior.  Initialize on whichever single thread will own
// all Julia interaction (a dedicated worker thread is the usual choice,
// so a long-running Julia call can never freeze the UI).
int julia_ios_init_with_paths(const char *framework_path,
                              const char *resources_path);

// Force interpreter fallback (--compile=min) for code that is not baked
// into the sysimage.  MUST be called before julia_ios_init_with_paths /
// jl_init (but after the Julia framework is loaded, which dyld has done
// by the time any app code runs).
//
// Why: iOS forbids third-party apps from allocating executable memory,
// so Julia's JIT cannot run on a physical device — the first call to a
// method that was not precompiled into sys.dylib would abort the app.
// With interpreter fallback, sysimage-baked code still runs at full
// native speed, and anything else runs (slowly) in the interpreter
// instead of crashing.  The iOS simulator runs under macOS rules where
// the JIT works, so calling this is only required for device builds —
// but interpreting is also the App Store-safe configuration (executing
// only code shipped in the bundle).
void julia_ios_set_interpreter_fallback(void);

// Run the standard jl_atexit_hook(0).  Call at app teardown.
void julia_ios_atexit(void);

#ifdef __cplusplus
}
#endif

#endif // JULIA_IOS_INIT_H
