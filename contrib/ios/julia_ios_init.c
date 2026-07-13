// julia_ios_init.c — see julia_ios_init.h.
//
// This file is intentionally minimal and depends only on libjulia's public
// API (julia.h).  Compile it as part of the iOS app target, alongside the
// embedded Julia.framework.

#include "julia_ios_init.h"

#include <dlfcn.h>
#include <julia.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int is_dir(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

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

void julia_ios_set_paths(const char *resources_path)
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
    // artifacts/<sha>/.  These live at the resources root, not under
    // share/julia, so this must be set explicitly (the BINDIR-relative
    // depot default would point at <resources>/share/julia).  No trailing
    // ':' — that would also search ~/.julia, which doesn't exist on iOS.
    setenv("JULIA_DEPOT_PATH", resources_path, 1);
    // LOAD_PATH = `@` (active project) + `@stdlib`.  `@stdlib` expands to
    // Sys.STDLIB, which is now correct by virtue of JULIA_BINDIR above.
    setenv("JULIA_LOAD_PATH", "@:@stdlib", 1);
    setenv("JULIA_PROJECT", resources_path, 1);
}

int julia_ios_init_with_paths(const char *framework_path,
                              const char *resources_path)
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
    // tree.  Must happen before jl_init: Base reads these env vars and
    // computes Sys.STDLIB during sysimage load.
    julia_ios_set_paths(resources_path);

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

void julia_ios_atexit(void)
{
    jl_atexit_hook(0);
}
