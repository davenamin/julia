// julia_ios_init.c — see julia_ios_init.h.
//
// This file is intentionally minimal and depends only on libjulia's public
// API (julia.h).  Compile it as part of the iOS app target, alongside the
// embedded Julia.framework.

#include "julia_ios_init.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// Locate julia.h wherever the app's build settings expose it.  When the app
// embeds Julia.xcframework, Xcode's framework search paths make the headers
// visible as <Julia/...> (Headers/julia/julia.h inside the framework, so the
// framework-style path is <Julia/julia/julia.h>; <Julia/Julia.h> is the
// umbrella header).  A plain <julia.h> works when HEADER_SEARCH_PATHS points
// directly at the framework's Headers/julia directory (or at a julia source
// tree's usr/include/julia).
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

static int is_dir(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

// Set by julia_ios_enable_jit() to suppress the device-default interpreter
// fallback in julia_ios_init_with_paths.
static int jit_requested = 0;

// Directory of the Julia framework instance ACTUALLY LOADED into this
// process, per dyld.  This can differ from the app-bundle framework path:
// in simulator Debug builds, Xcode's rpath resolves the app's framework
// link against the Build/Products (DerivedData) copy, not the embedded
// one.  The sysimage must be opened from the same framework SET the
// runtime was loaded from — opening the embedded copy would drag in a
// SECOND set of Julia dylibs (dyld dedupes by path, not content) and
// jl_init then dies with "System image file failed consistency check".
static int loaded_framework_dir(char *out, size_t outsize)
{
    Dl_info info;
    if (!dladdr((void *)&jl_init_with_image, &info) || !info.dli_fname)
        return -1;
    const char *slash = strrchr(info.dli_fname, '/');
    if (!slash)
        return -1;
    size_t len = (size_t)(slash - info.dli_fname);
    if (len + 1 > outsize)
        return -1;
    memcpy(out, info.dli_fname, len);
    out[len] = '\0';
    return 0;
}

void julia_ios_set_paths(const char *resources_path,
                         const char *writable_depot_path)
{
    if (!resources_path)
        return;

    // JULIA_BINDIR is the anchor Julia resolves everything path-relative
    // from: Base computes Sys.STDLIB as BINDIR/../share/julia/stdlib/vX.Y
    // (base/sysinfo.jl), MozillaCACerts_jll computes cert.pem as
    // BINDIR/../share/julia/cert.pem, and Pkg derives its stdlib directory
    // the same way.  We ship all of those under <resources>/share/julia/,
    // so pointing BINDIR at <resources>/bin makes every one of those
    // lookups resolve correctly with no post-init patching.  The bin/
    // directory itself need not contain anything (there is no julia
    // executable on iOS); build-xcframework.sh creates it so BINDIR names
    // a real path.  The sysimage and the dependency libraries are NOT found
    // via BINDIR — they load from the embedded frameworks through dyld
    // @rpath / dladdr — so BINDIR pointing away from the frameworks is safe.
    char bindir[2048];
    int n = snprintf(bindir, sizeof(bindir), "%s/bin", resources_path);
    if (n > 0 && (size_t)n < sizeof(bindir))
        setenv("JULIA_BINDIR", bindir, 1);

    // Depot = where Pkg looks for packages/<Name>/<HASH7>/ and
    // artifacts/<sha>/.  The bundled depot lives at the resources root (not
    // under share/julia), so this must be set explicitly (the BINDIR-relative
    // depot default would point at <resources>/share/julia).  No trailing
    // ':' — that would also search ~/.julia, which doesn't exist on iOS.
    //
    // The app bundle is READ-ONLY on device.  Julia treats the FIRST depot
    // entry as the writable one — Scratch.jl spaces (<depot>/scratchspaces),
    // logs, compiled caches, and Pkg mutations all go there — and a package
    // whose __init__ touches a scratch space dies with
    // InitError(... mkdir(".../<app-bundle>/scratchspaces") ... EPERM)
    // when the bundle depot comes first.  So when the caller supplies a
    // writable location, put it FIRST and the bundled depot second: reads
    // (packages/, artifacts/) search every entry, so the baked packages
    // still resolve from the bundle.
    if (writable_depot_path && writable_depot_path[0]) {
        // Best-effort creation: Julia lazily mkpath()s depot subdirs, so the
        // directory itself need not exist as long as its parent is writable.
        // EEXIST and other failures are deliberately not fatal here.
        mkdir(writable_depot_path, 0755);
        char depot[4096];
        int d = snprintf(depot, sizeof(depot), "%s:%s",
                         writable_depot_path, resources_path);
        if (d > 0 && (size_t)d < sizeof(depot))
            setenv("JULIA_DEPOT_PATH", depot, 1);
        else
            setenv("JULIA_DEPOT_PATH", resources_path, 1);
    }
    else {
        setenv("JULIA_DEPOT_PATH", resources_path, 1);
    }
    // LOAD_PATH = `@` (active project) + `@stdlib`.  `@stdlib` expands to
    // Sys.STDLIB, which is now correct by virtue of JULIA_BINDIR above.
    setenv("JULIA_LOAD_PATH", "@:@stdlib", 1);
    setenv("JULIA_PROJECT", resources_path, 1);

    // App Store Guideline 2.5.2 guardrail: apps may not download and execute
    // code.  With Pkg's networking stack shipped and a writable depot, a
    // stray `Pkg.add`/`Pkg.update` in app code would fetch packages the
    // interpreter then runs.  Default Pkg to offline mode — resolve /
    // instantiate keep working against the bundled depot.  overwrite=0: a
    // value the app already set (e.g. JULIA_PKG_OFFLINE=false before this
    // call, for a dev build) wins.
    setenv("JULIA_PKG_OFFLINE", "true", 0);
}

int julia_ios_init_with_paths(const char *framework_path,
                              const char *resources_path,
                              const char *writable_depot_path)
{
    if (!is_dir(framework_path)) {
        fprintf(stderr, "julia_ios_init: framework_path is not a directory: %s\n",
                framework_path ? framework_path : "(null)");
        return -1;
    }
    if (!is_dir(resources_path)) {
        fprintf(stderr, "julia_ios_init: resources_path is not a directory: %s\n",
                resources_path ? resources_path : "(null)");
        return -1;
    }
    if (writable_depot_path && writable_depot_path[0] && !is_dir(writable_depot_path)) {
        // julia_ios_set_paths() will attempt to create it; only reject when
        // the PARENT can't take a mkdir, since then nothing at runtime could
        // write there either and package InitErrors would follow.
        if (mkdir(writable_depot_path, 0755) != 0 && !is_dir(writable_depot_path)) {
            fprintf(stderr,
                    "julia_ios_init: writable_depot_path cannot be created: %s\n",
                    writable_depot_path);
            return -1;
        }
    }

    // Locate the sysimage relative to the framework directory dyld actually
    // loaded libjulia from (see loaded_framework_dir()); the caller-supplied
    // framework_path is only the fallback if dladdr fails.  This is a
    // separate concern from JULIA_BINDIR: the sysimage must come from the
    // loaded framework set, but BINDIR points at the resources tree.
    char fw_dir[2048];
    if (loaded_framework_dir(fw_dir, sizeof(fw_dir)) != 0) {
        int m = snprintf(fw_dir, sizeof(fw_dir), "%s", framework_path);
        if (m < 0 || (size_t)m >= sizeof(fw_dir)) {
            fprintf(stderr, "julia_ios_init: framework path too long\n");
            return -1;
        }
    }
    else if (strcmp(fw_dir, framework_path) != 0) {
        fprintf(stderr,
                "julia_ios_init: note: libjulia was loaded from\n"
                "  %s\n"
                "which differs from the supplied framework_path\n"
                "  %s\n"
                "— using the loaded location for the sysimage to keep the "
                "runtime and sysimage in the same framework set.\n",
                fw_dir, framework_path);
    }

    // Set JULIA_BINDIR / depot / project / load-path from the resources
    // tree (+ the writable depot, when given).  Must happen before jl_init:
    // Base reads these env vars and computes Sys.STDLIB during sysimage load.
    julia_ios_set_paths(resources_path, writable_depot_path);

    // Point the bindir argument at the same <resources>/bin.  jl_init_with_image
    // assigns it straight into jl_options.julia_bindir (src/jlapi.c), and it
    // takes precedence over the JULIA_BINDIR env var, so pass it explicitly
    // to be unambiguous.
    char bindir[2048];
    int b = snprintf(bindir, sizeof(bindir), "%s/bin", resources_path);
    if (b < 0 || (size_t)b >= sizeof(bindir)) {
        fprintf(stderr, "julia_ios_init: resources path too long\n");
        return -1;
    }

    // The sysimage ships as its own single-binary framework (App Store rule:
    // no loose dylibs) named JuliaSysimage.framework, a SIBLING of
    // Julia.framework in the app's Frameworks/ directory.  fw_dir is the
    // Julia.framework directory, so hop up one level and into the sysimage
    // framework.  Pass the absolute path so jl_init_with_image doesn't
    // derive it from bindir.
    char image[2048];
    int n = snprintf(image, sizeof(image),
                     "%s/../JuliaSysimage.framework/JuliaSysimage", fw_dir);
    if (n < 0 || (size_t)n >= sizeof(image)) {
        fprintf(stderr, "julia_ios_init: framework path too long\n");
        return -1;
    }

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE && \
    defined(TARGET_OS_SIMULATOR) && !TARGET_OS_SIMULATOR
    // Physical device: iOS forbids third-party apps from mapping executable
    // memory, so the JIT cannot work — the first compilation attempt for a
    // method not baked into the sysimage kills the app with EXC_BAD_ACCESS.
    // A crash during App Store review is a Guideline 2.1 rejection no matter
    // the cause, so interpreter fallback is the DEFAULT on device and JIT is
    // the explicit opt-out (julia_ios_enable_jit, for e.g. side-loaded
    // development scenarios).  The simulator runs under macOS rules where
    // the JIT works, so it is unaffected by this default.
    if (!jit_requested)
        jl_options.compile_enabled = JL_OPTIONS_COMPILE_MIN;
#endif

    jl_init_with_image(bindir, image);
    return jl_exception_occurred() ? -1 : 0;
}

void julia_ios_set_interpreter_fallback(void)
{
    // jl_options is initialized by libjulia's load-time constructor
    // (before any app code runs) precisely so embedders can adjust it
    // between load and jl_init; see cli/loader_lib.c.
    jl_options.compile_enabled = JL_OPTIONS_COMPILE_MIN;
}

void julia_ios_enable_jit(void)
{
    jit_requested = 1;
}

// Print whatever Julia raised, not just its type name: for an interpreted
// `ccall` the message names the reason (unsupported argument class, missing
// symbol, ...), which is the only thing worth having from a device log.
//
// The stream comes from jl_stderr_stream(), not the JL_STDERR macro.  That
// macro expands to the `jl_uv_stderr` variable, which libjulia-internal
// defines but does not re-export through libjulia — the only library an app
// links against — so using it here fails the app link with
// "Undefined symbol: _jl_uv_stderr".  jl_stderr_stream() is an exported
// accessor for the same stream.
static void report_julia_exception(const char *what)
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

int julia_ios_blas_report(void)
{
    // LinearAlgebra is already in the sysimage, so `using` here only binds the
    // name — it does not go near the depot or trigger precompilation.  The
    // report itself is a baked method, which matters: device builds run under
    // --compile=min, and the interpreter cannot execute the `ccall`s that
    // reading libblastrampoline's config requires.  Calling a compiled
    // function from interpreted code is fine; inlining the ccalls here would
    // not be.
    // `LAPACK.version()` reports whichever library the trampoline resolved
    // ilaver_ to, which on iOS is Accelerate shadowing OpenBLAS — worth having
    // next to the per-symbol map when a factorization result is in question.
    jl_eval_string("using LinearAlgebra: BLAS, LAPACK; BLAS.report(); "
                   "println(stderr, \"  LAPACK version   = \", LAPACK.version())");
    if (jl_exception_occurred()) {
        report_julia_exception("julia_ios_blas_report");
        return -1;
    }
    return 0;
}

// The cases are written as source and evaluated here rather than baked, so
// their top-level thunks are interpreted — which is the whole point, since a
// baked `ccall` would be a compiled one and prove nothing.  No closures and no
// generic containers, to keep the snippet itself within what the interpreter
// handles comfortably.
//
// Each case carries its own try/catch so one unsupported signature reports its
// reason and the rest still run: the interpreter raises a descriptive error for
// anything it cannot marshal (see src/interpreter-ccall.c), and that message is
// the useful part of a device run.
static const char *ccall_selftest_src =
    "let f = 0, n = 0\n"
    "  println(stderr, \"julia_ios_ccall_selftest: compile_enabled=\",\n"
    "          Base.JLOptions().compile_enabled, \" (3 = min, interpreter fallback)\")\n"

    "  n += 1\n"
    "  try\n"
    "    r = ccall(:abs, Cint, (Cint,), -5)\n"
    "    ok = r == Cint(5); f += ok ? 0 : 1\n"
    "    println(stderr, \"  abs(-5)            -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  abs(-5)            -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    r = ccall(:strlen, Csize_t, (Cstring,), \"hello\")\n"
    "    ok = r == Csize_t(5); f += ok ? 0 : 1\n"
    "    println(stderr, \"  strlen(hello)      -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  strlen(hello)      -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    r = ccall(:sqrt, Cdouble, (Cdouble,), 2.0)\n"
    "    ok = r == sqrt(2.0); f += ok ? 0 : 1\n"
    "    println(stderr, \"  sqrt(2.0)          -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  sqrt(2.0)          -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    r = ccall(:ldexp, Cdouble, (Cdouble, Cint), 1.5, 3)\n"
    "    ok = r == 12.0; f += ok ? 0 : 1\n"
    "    println(stderr, \"  ldexp(1.5, 3)      -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  ldexp(1.5, 3)      -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    r = ccall(:fabsf, Cfloat, (Cfloat,), -2.5f0)\n"
    "    ok = r == 2.5f0; f += ok ? 0 : 1\n"
    "    println(stderr, \"  fabsf(-2.5f0)      -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  fabsf(-2.5f0)      -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    s = \"abcdef\"\n"
    "    p = ccall(:memchr, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t),\n"
    "              pointer(s), Int32('c'), sizeof(s))\n"
    "    d = Int(p - pointer(s))\n"
    "    ok = d == 2; f += ok ? 0 : 1\n"
    "    println(stderr, \"  memchr(abcdef, c)  -> offset \", d, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  memchr(abcdef, c)  -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    ccall(:free, Cvoid, (Ptr{Cvoid},), C_NULL)\n"
    "    println(stderr, \"  free(C_NULL)       -> returned\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  free(C_NULL)       -> \", sprint(showerror, e))\n"
    "  end\n"

    // A boxed argument and a boxed return: both travel as a bare jl_value_t*.
    "  n += 1\n"
    "  try\n"
    "    r = ccall(:jl_box_int64, Any, (Int64,), 7)\n"
    "    ok = r === 7; f += ok ? 0 : 1\n"
    "    println(stderr, \"  jl_box_int64(7)    -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  jl_box_int64(7)    -> \", sprint(showerror, e))\n"
    "  end\n"

    "  n += 1\n"
    "  try\n"
    "    v = ccall(:jl_alloc_array_1d, Vector{Float64}, (Any, Csize_t),\n"
    "              Vector{Float64}, 3)\n"
    "    ok = v isa Vector{Float64} && length(v) == 3; f += ok ? 0 : 1\n"
    "    println(stderr, \"  alloc Vector{F64}  -> \", typeof(v), \" length \", length(v),\n"
    "            ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  alloc Vector{F64}  -> \", sprint(showerror, e))\n"
    "  end\n"

    // An isbits struct by value.  ComplexF64 is two Float64s, which AAPCS64
    // passes as a homogeneous float aggregate in v0/v1 rather than in GPRs.
    "  n += 1\n"
    "  try\n"
    "    r = ccall(:cabs, Cdouble, (ComplexF64,), 3.0 + 4.0im)\n"
    "    ok = r == 5.0; f += ok ? 0 : 1\n"
    "    println(stderr, \"  cabs(3+4im)        -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  cabs(3+4im)        -> \", sprint(showerror, e))\n"
    "  end\n"

    // A struct returned by value.
    "  n += 1\n"
    "  try\n"
    "    r = ccall(:ldiv, Tuple{Clong,Clong}, (Clong, Clong), 17, 5)\n"
    "    ok = r === (Clong(3), Clong(2)); f += ok ? 0 : 1\n"
    "    println(stderr, \"  ldiv(17, 5)        -> \", r, ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  ldiv(17, 5)        -> \", sprint(showerror, e))\n"
    "  end\n"

    // `Ref{T}` as a return type: the callee returns a bare jl_value_t*, which
    // codegen types as `Any` rather than checking it against `T`.  This is how
    // Base spells `current_task()`, so it is on the path of anything that
    // touches tasks or locks.
    "  n += 1\n"
    "  try\n"
    "    t = ccall(:jl_get_current_task, Ref{Task}, ())\n"
    "    ok = t === current_task(); f += ok ? 0 : 1\n"
    "    println(stderr, \"  Ref{Task} return   -> \", typeof(t), ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  Ref{Task} return   -> \", sprint(showerror, e))\n"
    "  end\n"

    // `Ref{T}` as an argument type: by this point the ccall lowering has run
    // `unsafe_convert`, so the value is a pointer and C is handed the pointer,
    // not the box holding it.
    "  n += 1\n"
    "  try\n"
    "    ip = Ref(Cdouble(0))\n"
    "    fr = ccall(:modf, Cdouble, (Cdouble, Ref{Cdouble}), 3.75, ip)\n"
    "    ok = fr == 0.75 && ip[] == 3.0; f += ok ? 0 : 1\n"
    "    println(stderr, \"  modf(3.75) [Ref arg]-> frac \", fr, \" int \", ip[],\n"
    "            ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  modf(3.75) [Ref arg]-> \", sprint(showerror, e))\n"
    "  end\n"

    // A variadic callee.  The `;` is load-bearing: it sets the count of fixed
    // arguments, which is what selects ffi_prep_cif_var.  Declaring the
    // variadic arguments as though they were fixed passes them in registers,
    // and Apple's arm64 ABI puts them on the stack.
    "  n += 1\n"
    "  try\n"
    "    b = Vector{UInt8}(undef, 64)\n"
    "    m = @ccall snprintf(b::Ptr{UInt8}, length(b)::Csize_t,\n"
    "                        \"%d %.2f\"::Cstring; 42::Cint, 2.5::Cdouble)::Cint\n"
    "    s = unsafe_string(pointer(b))\n"
    "    ok = m == 7 && s == \"42 2.50\"; f += ok ? 0 : 1\n"
    "    println(stderr, \"  snprintf varargs   -> \", repr(s), ok ? \"\" : \"  WRONG\")\n"
    "  catch e\n"
    "    f += 1; println(stderr, \"  snprintf varargs   -> \", sprint(showerror, e))\n"
    "  end\n"

    "  println(stderr, \"julia_ios_ccall_selftest: \", n - f, \"/\", n, \" cases passed\")\n"
    "  f\n"
    "end";

int julia_ios_ccall_selftest(void)
{
    jl_value_t *res = jl_eval_string(ccall_selftest_src);
    if (jl_exception_occurred() || res == NULL) {
        report_julia_exception("julia_ios_ccall_selftest");
        return -1;
    }
    return (int)jl_unbox_long(res);
}

void julia_ios_atexit(void)
{
    jl_atexit_hook(0);
}
