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
// one.  sys.dylib must be opened from the same instance the runtime was
// loaded from — opening the embedded copy would drag in a SECOND set of
// Julia dylibs (dyld dedupes by path, not content) and jl_init then dies
// with "System image file failed consistency check".
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

void julia_ios_set_paths(const char *framework_path,
                         const char *resources_path)
{
    if (framework_path) {
        // JULIA_BINDIR is where Julia looks for ../share/julia/stdlib, sys.dylib,
        // etc.  On iOS we point it at the framework dir; the resources path
        // override below then redirects stdlib lookups.
        setenv("JULIA_BINDIR", framework_path, 1);
    }
    if (resources_path) {
        // Depot = where Pkg looks for packages/<Name>/<HASH7>/ and
        // artifacts/<sha>/.  Trailing ':' would make Julia also search the
        // default user depot (~/.julia), which doesn't exist on iOS — keep
        // it bounded to the bundled tree.
        setenv("JULIA_DEPOT_PATH", resources_path, 1);
        // LOAD_PATH = `@` (active project) + `@stdlib`.  The active project
        // comes from JULIA_PROJECT below.
        setenv("JULIA_LOAD_PATH", "@:@stdlib", 1);
        setenv("JULIA_PROJECT", resources_path, 1);
        // CA roots for NetworkOptions / Downloads / LibGit2.  Their default
        // fallback is JULIA_BINDIR/../share/julia/cert.pem, which resolves
        // next to the framework where nothing is installed; point them at
        // the copy bundled in the resources tree instead.
        char certs[2048];
        int n = snprintf(certs, sizeof(certs), "%s/share/julia/cert.pem",
                         resources_path);
        struct stat st;
        if (n > 0 && (size_t)n < sizeof(certs) &&
            stat(certs, &st) == 0 && S_ISREG(st.st_mode)) {
            setenv("JULIA_SSL_CA_ROOTS_PATH", certs, 1);
        }
    }
}

// Escape a path for embedding inside a Julia double-quoted string literal:
// backslash, double-quote, and $ (interpolation) must be backslash-escaped.
// Returns 0 on success, -1 if the escaped form does not fit in `out`.
static int escape_julia_string(const char *src, char *out, size_t outsize)
{
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0'; i++) {
        char c = src[i];
        if (c == '\\' || c == '"' || c == '$') {
            if (j + 1 >= outsize)
                return -1;
            out[j++] = '\\';
        }
        if (j + 1 >= outsize)
            return -1;
        out[j++] = c;
    }
    out[j] = '\0';
    return 0;
}

// Push Sys.STDLIB and LOAD_PATH so they reflect the bundled resources tree
// rather than whatever JULIA_BINDIR happened to compute.  Must run *after*
// jl_init has loaded the sysimage (Sys.STDLIB is set during Base init).
static int apply_runtime_overrides(const char *resources_path)
{
    if (!resources_path)
        return 0;
    char res_escaped[1024];
    if (escape_julia_string(resources_path, res_escaped, sizeof(res_escaped)) != 0) {
        fprintf(stderr, "julia_ios_init: resources path too long\n");
        return -1;
    }
    // Build "$resources/share/julia/stdlib/v$(VERSION.major).$(VERSION.minor)"
    // in Julia rather than via sprintf — VERSION is the only reliable source
    // of the vX.Y suffix once Base has loaded.
    char script[2048];
    int n = snprintf(script, sizeof(script),
        "let res = \"%s\";\n"
        "  ver = string(\"v\", VERSION.major, '.', VERSION.minor);\n"
        "  Sys.STDLIB = joinpath(res, \"share\", \"julia\", \"stdlib\", ver);\n"
        "  empty!(LOAD_PATH);\n"
        "  push!(LOAD_PATH, \"@\", \"@stdlib\");\n"
        "  empty!(DEPOT_PATH);\n"
        "  push!(DEPOT_PATH, res);\n"
        "  nothing\n"
        "end\n",
        res_escaped);
    if (n < 0 || (size_t)n >= sizeof(script)) {
        fprintf(stderr, "julia_ios_init: resources path too long\n");
        return -1;
    }
    jl_value_t *result = jl_eval_string(script);
    if (jl_exception_occurred()) {
        fprintf(stderr, "julia_ios_init: override eval failed: %s\n",
                jl_typeof_str(jl_exception_occurred()));
        return -1;
    }
    (void)result;
    return 0;
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

    // Prefer the framework directory dyld actually loaded libjulia from
    // over the caller-supplied path; see loaded_framework_dir().  The
    // caller's path is only the fallback if dladdr somehow fails.
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
                "— using the loaded location for sys.dylib to keep the "
                "runtime and sysimage in the same framework instance.\n",
                fw_dir, framework_path);
    }

    julia_ios_set_paths(fw_dir, resources_path);

    // sys.dylib lives next to libjulia.dylib inside the framework.  Pass
    // the absolute path so jl_init_with_image doesn't have to guess.
    char image[2048];
    int n = snprintf(image, sizeof(image), "%s/sys.dylib", fw_dir);
    if (n < 0 || (size_t)n >= sizeof(image)) {
        fprintf(stderr, "julia_ios_init: framework path too long\n");
        return -1;
    }

    jl_init_with_image(fw_dir, image);

    return apply_runtime_overrides(resources_path);
}

void julia_ios_atexit(void)
{
    jl_atexit_hook(0);
}
