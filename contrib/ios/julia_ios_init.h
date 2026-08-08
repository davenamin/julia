// julia_ios_init.h — helper for embedding the Julia framework set into an
// iOS app.
//
// Julia ships as a SET of single-binary frameworks (App Store rule: apps
// may not contain loose dylibs): Julia.framework (libjulia, the one the app
// links against), libjulia-internal.framework, libjulia-codegen.framework,
// JuliaSysimage.framework (the baked sysimage), and one framework per
// dependency library — all embedded side by side in the app's Frameworks/
// directory ("Embed & Sign" every one of them).  The iOS app additionally
// needs to ship the "runtime resources" tree produced by
// contrib/ios/build-xcframework.sh (julia-runtime-resources/) so Julia can
// locate its stdlib + any packages baked into the sysimage.
//
// The functions below wire up the paths and call jl_init_with_image with
// the sibling JuliaSysimage.framework's binary as the image, before Julia
// is asked to do anything else.
//
// Usage (Swift app, after Embed & Sign of all the Julia frameworks):
//
//   guard let fwUrl = Bundle.main.privateFrameworksURL?
//           .appendingPathComponent("Julia.framework"),
//         let resUrl = Bundle.main.url(forResource: "julia-runtime-resources",
//                                      withExtension: nil)
//   else { fatalError("Julia.framework or resources not in bundle") }
//   let depotUrl = FileManager.default.urls(for: .applicationSupportDirectory,
//                                           in: .userDomainMask)[0]
//           .appendingPathComponent("julia-depot")
//   julia_ios_init_with_paths(fwUrl.path, resUrl.path, depotUrl.path)
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
//   resources_path:      absolute path to the julia-runtime-resources
//                        directory shipped in the app bundle.
//   writable_depot_path: absolute path to a WRITABLE directory for Julia's
//                        primary depot (e.g. a subdirectory of the app's
//                        Application Support directory).  May be NULL to
//                        run with only the read-only bundle depot.
//
// Sets JULIA_BINDIR=<resources>/bin (so Sys.STDLIB, the CA cert path, and
// Pkg's stdlib directory — all computed as BINDIR/../share/julia/... —
// land in the shipped tree), plus JULIA_DEPOT_PATH / JULIA_PROJECT /
// JULIA_LOAD_PATH.  Note BINDIR does NOT point at the frameworks: the
// sysimage and the dependency libraries load via dyld @rpath / the
// framework-aware dlopen fallback, not relative to BINDIR.
//
// Depot layering: Julia writes to the FIRST depot entry — Scratch.jl spaces
// (<depot>/scratchspaces), logs, compiled caches, Pkg mutations — while
// package/artifact lookups search every entry.  The app bundle is read-only
// on device, so with writable_depot_path set the depot becomes
// "<writable>:<resources>": writes land in the writable depot and the baked
// packages still resolve from the bundle.  Without it, any package whose
// __init__ touches a scratch space fails at load with
// InitError(... mkdir ... EPERM).  The directory is created if missing
// (single level; the parent must exist and be writable).
//
// Also defaults JULIA_PKG_OFFLINE=true (App Store Guideline 2.5.2: apps may
// not download and execute code, and `Pkg.add` at runtime would do exactly
// that).  Pkg.resolve / Pkg.instantiate keep working against the bundled
// depot.  A value the app sets in the environment BEFORE this call wins —
// e.g. setenv("JULIA_PKG_OFFLINE", "false", 1) for a development build.
void julia_ios_set_paths(const char *resources_path,
                         const char *writable_depot_path);

// NOTE: the framework_path argument (path to Julia.framework) is validated
// but used only as a fallback for locating the sysimage — the sysimage
// (../JuliaSysimage.framework/JuliaSysimage) is resolved relative to the
// framework directory dyld actually loaded libjulia from (found via
// dladdr), which may differ from the embedded copy (e.g. simulator Debug
// builds resolve the app's framework link against DerivedData's
// Build/Products).  Mixing the two loads a second set of Julia dylibs and
// fails jl_init's sysimage consistency check.
//
// Combines julia_ios_set_paths + jl_init_with_image into one call: it
// points JULIA_BINDIR at <resources>/bin, layers the writable depot in
// front of the bundled one (see julia_ios_set_paths — pass NULL to skip),
// opens the sibling JuliaSysimage.framework's binary as the system image,
// and calls jl_init_with_image.  No post-init patching is needed — Base
// computes Sys.STDLIB (and Pkg its stdlib dir) from BINDIR, which now
// resolves into the resources tree.  Returns 0 on success, -1 on failure
// (framework_path or resources_path missing/not a directory,
// writable_depot_path non-NULL but uncreatable, or an exception during
// jl_init).
//
// On PHYSICAL DEVICES this defaults Julia to interpreter fallback
// (--compile=min): the iOS JIT prohibition means the first compilation of
// a method not baked into the sysimage would crash the app, and a crash
// during App Store review is a Guideline 2.1 rejection.  Sysimage-baked
// code is unaffected (it runs natively); only non-baked code interprets.
// Call julia_ios_enable_jit() beforehand to opt out (development only).
// The simulator keeps the JIT.
//
// THREADING: the thread this runs on becomes Julia's main thread — all
// later jl_eval_string / jl_call* invocations must happen on that same
// thread (or via Julia-side threading primitives).  Initializing on a
// dispatch queue and then calling into Julia from the UI thread is
// undefined behavior.  Initialize on whichever single thread will own
// all Julia interaction (a dedicated worker thread is the usual choice,
// so a long-running Julia call can never freeze the UI).
int julia_ios_init_with_paths(const char *framework_path,
                              const char *resources_path,
                              const char *writable_depot_path);

// Force interpreter fallback (--compile=min) for code that is not baked
// into the sysimage.  MUST be called before julia_ios_init_with_paths /
// jl_init (but after the Julia framework is loaded, which dyld has done
// by the time any app code runs).
//
// Why: iOS forbids third-party apps from allocating executable memory,
// so Julia's JIT cannot run on a physical device — the first call to a
// method that was not precompiled into the sysimage would abort the app.
// With interpreter fallback, sysimage-baked code still runs at full
// native speed, and anything else runs (slowly) in the interpreter
// instead of crashing.
//
// NOTE: on physical devices julia_ios_init_with_paths applies this mode BY
// DEFAULT (a JIT crash during App Store review is a Guideline 2.1 rejection;
// see julia_ios_enable_jit for the opt-out).  Calling this explicitly is
// therefore only needed to (a) get interpreter semantics on the SIMULATOR,
// e.g. to reproduce device behavior during development, or (b) force the
// mode when initializing via raw jl_init* instead of the helper.
void julia_ios_set_interpreter_fallback(void);

// Opt OUT of the device-default interpreter fallback: keep the JIT enabled
// on a physical device.  MUST be called before julia_ios_init_with_paths.
//
// Only meaningful for scenarios where executable memory is actually
// available (development side-loading with the right entitlements,
// jailbroken devices).  On a normal device / App Store build the first JIT
// compilation will crash the app with EXC_BAD_ACCESS — do not ship this.
// Has no effect on the simulator, where the JIT is always available.
void julia_ios_enable_jit(void);

// Print the live BLAS/LAPACK configuration to stderr: the libraries
// libblastrampoline has loaded, their integer interface, and which library
// actually backs a representative spread of BLAS and LAPACK symbols.
//
// Worth calling once from a device build.  Julia forwards Apple's Accelerate
// on top of OpenBLAS at startup, so BLAS and LAPACK come from Accelerate
// wherever it exports a symbol and from OpenBLAS otherwise (the cross-built
// OpenBLAS is NOFORTRAN, which selects its C_LAPACK sources rather than
// dropping LAPACK).  This is how you confirm the forward happened, and see
// which symbols Accelerate covers versus which fall back.  A symbol reported UNBOUND aborts
// the process if anything calls it.
//
// Must be called after julia_ios_init_with_paths().  Returns 0 on success,
// -1 if Julia raised (the report itself never raises).
int julia_ios_blas_report(void);

// Check that `ccall` works from interpreted code, printing one line per case
// to stderr and returning the number of failures (negative if the check could
// not be run at all).
//
// Device builds run everything outside the sysimage in the interpreter, which
// performs foreign calls without generating code (src/interpreter-ccall.c).
// This exercises that: the cases are evaluated from source at runtime, so they
// are not in the sysimage and cannot be running compiled.  Worth calling once
// from a device build, since the interpreted path is the one no desktop test
// covers.
//
// Must be called after julia_ios_init_with_paths().
int julia_ios_ccall_selftest(void);

// Run the standard jl_atexit_hook(0).  Call at app teardown.
void julia_ios_atexit(void);

#ifdef __cplusplus
}
#endif

#endif // JULIA_IOS_INIT_H
