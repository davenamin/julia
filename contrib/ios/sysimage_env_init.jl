# This file is a part of Julia. License is MIT: https://julialang.org/license

# Loaded via `-L` at the start of the iOS sysimage bake's stage 3, before any
# IOS_SYSIMAGE_EXTRA_JL warm-up files (see sysimage-ios.mk).  Only loaded for
# bakes that have extra code or packages; a plain bake needs none of this.
#
# Stage 3 runs the host julia in `--output-o` mode, which does not run
# `Base.__init__`.  Two consequences have to be undone here before a warm-up
# file can `using` anything.
#
# 1. The loading environment is empty — `Sys.STDLIB == ""`, `LOAD_PATH == []`,
#    `DEPOT_PATH == []`, no active project — even though the bake exports the
#    matching JULIA_* variables.  `using SomePkg` fails with "not found in
#    current path", or, once LOAD_PATH is set, on `readdir("")` inside
#    `is_stdlib`.  Re-run the loading steps, honouring that environment.
#
# 2. stdio globals are still the raw `Core.CoreSTDOUT`/… handles, which have no
#    `redirect_stdout` method.  A package that redirects stdio at load time
#    (Test's precompile.jl does) must be able to save and restore it, and
#    `reinit_stdio()` binds the globals to real libuv streams so that
#    round-trip works.  It serializes fine — the output image's own
#    `Base.__init__` overwrites these at startup.
#
#    It must run exactly ONCE per process.  A second call wraps the same
#    fd 0/1/2 libuv handles in fresh stream objects, and finalizing the
#    orphaned first set calls `jl_close_uv` on the *shared* handle, after which
#    every write fails with `EBADF`.  `generate_precompile.jl` would call it
#    too, so for extra-package bakes sysimage-ios.mk passes it arg `0`, which
#    skips that call along with all statement collection.
Base.reinit_stdio()
Base.Sys.__init_build()      # Sys.BINDIR + Sys.STDLIB (from JULIA_BINDIR)
Base.init_depot_path()       # DEPOT_PATH (JULIA_DEPOT_PATH or default depot)
Base.init_load_path()        # LOAD_PATH (JULIA_LOAD_PATH, e.g. @:@stdlib)
Base.init_active_project()   # active project (JULIA_PROJECT)

# `--output-o` also *defers* each restored module's `__init__`:
# `jl_init_restored_module` only queues the module into `jl_module_init_order`
# for the output image to run at its own startup (src/module.c), so baked
# stdlibs are present but uninitialized during the bake.  LinearAlgebra is the
# one that bites — its `__init__` forwards BLAS/LAPACK into libblastrampoline,
# and without it every BLAS call dispatches through an unbound trampoline and
# segfaults, so a package evaluating anything numeric at load time (Colors
# evaluates a top-level `inv`) crashes the bake before `using` returns.
# PackageCompiler avoids this only by building incremental images, where the
# same C path runs the initializers instead of deferring them.
#
# Call the initializers directly instead.  The deferred queue is untouched, so
# the output image still re-runs them at its own startup — on device that is
# where the real BLAS and paths get set up.  Skip Core (no `__init__`) and Base
# (`Base.__init__` starts threads and signal handlers inappropriate to a build
# process; its loading pieces are replicated above).
let loaded = Base.loaded_modules_array(),
    byname = Dict{Symbol,Module}(nameof(m) => m for m in loaded)

    # Run one restored module's initializer now, in this process.
    run_init = function (m)
        (m === nothing || m === Core || m === Base) && return
        isdefined(m, :__init__) || return
        try
            Base.invokelatest(getglobal(m, :__init__))
        catch ex
            Base.showerror_nostdio(ex, "WARNING: Error initializing $(nameof(m)) in sysimage bake")
        end
        return
    end

    # Drive the BLAS chain explicitly rather than leaving it to restore order,
    # which is not guaranteed to reach OpenBLAS_jll before LinearAlgebra.
    # LinearAlgebra.__init__ forwards into libblastrampoline, but only usefully
    # once OpenBLAS_jll.__init__ has set `libopenblas_path` — and that opens
    # `@rpath/libopenblas*.dylib`, which may not resolve in the bake process.
    # If it throws, the path is left "" and `lbt_forward(""; clear=true)` clears
    # the trampoline to a stub that aborts with "Quitting." on the first BLAS
    # call, so fall back to the host's bundled OpenBLAS by absolute path.
    ob = get(byname, :OpenBLAS_jll, nothing)
    if ob !== nothing
        run_init(ob)
        if isempty(getglobal(ob, :libopenblas_path))
            for nm in ("libopenblas64_", "libopenblas")
                p = joinpath(Sys.BINDIR, Base.LIBDIR, "julia",
                             string(nm, ".", Base.Libc.Libdl.dlext))
                isfile(p) || continue
                try
                    h = Base.Libc.Libdl.dlopen(p)
                    setglobal!(ob, :libopenblas_handle, h)
                    setglobal!(ob, :libopenblas_path, Base.Libc.Libdl.dlpath(h))
                    break
                catch ex
                    Base.showerror_nostdio(ex, "WARNING: could not dlopen host OpenBLAS at $p")
                end
            end
        end
        # Report which OpenBLAS the bake forwards.  Raw write rather than
        # `println`: this must stay readable if the stdio setup above failed.
        msg = string("iOS sysimage bake: forwarding BLAS from '",
                     getglobal(ob, :libopenblas_path), "'\n")
        ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, msg, sizeof(msg))
    end
    run_init(get(byname, :libblastrampoline_jll, nothing))
    run_init(get(byname, :LinearAlgebra, nothing))

    # Best effort: run the remaining restored modules' initializers too, so
    # other baked packages that rely on stdlib init at load time behave.  The
    # BLAS chain above is skipped here so it isn't re-run (and re-cleared) out
    # of order.
    blas_chain = (ob,
                  get(byname, :libblastrampoline_jll, nothing),
                  get(byname, :LinearAlgebra, nothing))
    for mod in loaded
        any(x -> x === mod, blas_chain) && continue
        run_init(mod)
    end
end
nothing
