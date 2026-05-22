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

// Set JULIA_BINDIR-equivalent env vars so Julia's runtime path lookups
// resolve into the framework + resources tree.  Safe to call before
// jl_init().  No-op if either argument is NULL.
//
//   framework_path: absolute path to the embedded Julia.framework directory
//                   (the dir containing libjulia.dylib, sys.dylib, ...).
//   resources_path: absolute path to the julia-runtime-resources directory
//                   shipped in the app bundle.
void julia_ios_set_paths(const char *framework_path,
                         const char *resources_path);

// NOTE: the framework_path argument is validated but used only as a
// fallback — sys.dylib is opened from the framework directory dyld
// actually loaded libjulia from (found via dladdr), which may differ
// from the embedded copy (e.g. simulator Debug builds resolve the
// app's framework link against DerivedData/Build/Products).  Mixing
// the two loads a second set of Julia dylibs and fails jl_init's
// sysimage consistency check.
//
// Call jl_init_with_image() using the framework's sys.dylib, then run
// `Sys.STDLIB = ...; empty!(LOAD_PATH); push!(LOAD_PATH, "@", "@stdlib")`
// so stdlib + the bundled Project resolve against the resources tree
// rather than wherever JULIA_BINDIR ended up pointing (which on iOS is
// the app's main bundle, not the framework).
//
// Combines julia_ios_set_paths + jl_init_with_image + post-init
// overrides into one call.  Returns 0 on success, -1 on failure
// (framework_path or resources_path missing or not a directory).
int julia_ios_init_with_paths(const char *framework_path,
                              const char *resources_path);

// Run the standard jl_atexit_hook(0).  Call at app teardown.
void julia_ios_atexit(void);

#ifdef __cplusplus
}
#endif

#endif // JULIA_IOS_INIT_H
