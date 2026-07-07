# This file is a part of Julia. License is MIT: https://julialang.org/license

# Loaded via `-L` at the start of the iOS sysimage bake's stage 3, before any
# IOS_SYSIMAGE_EXTRA_JL warm-up files (see sysimage-ios.mk).
#
# Why this is needed: stage 3 runs the host julia in `--output-o` (sysimage
# generation) mode, and in that mode Julia does NOT run `Base.__init__`.  So
# the whole package-loading environment is left uninitialized —
# `Sys.STDLIB == ""`, `LOAD_PATH == []`, `DEPOT_PATH == []`, and no active
# project — even though the bake exports JULIA_LOAD_PATH / JULIA_PROJECT /
# JULIA_BINDIR.  A `using SomePkg` in a warm-up file then fails with
# "Package SomePkg not found in current path" (empty LOAD_PATH), or, once
# LOAD_PATH is set, `readdir("")` inside `is_stdlib` (empty Sys.STDLIB).
#
# Re-run the loading-init steps `Base.__init__` performs, honoring the JULIA_*
# environment the bake already sets, so the extra project's packages resolve
# and load; then re-run the sysimage modules' own `__init__`s (which the same
# `--output-o` mode also skips) so stdlib runtime state — notably LinearAlgebra's
# BLAS/LAPACK forwarding — is live before any warm-up file loads.  These are
# no-ops for a bake with no extra packages (the preamble isn't loaded then).
#
# Re-initialize stdio.  In `--output-o` mode `Base.__init__` never ran, so
# `stdout`/`stderr`/`stdin` are still the raw `Core.CoreSTDOUT`/… handles.  A
# package that redirects stdio at load/precompile time — Test's `precompile.jl`
# does `redirect_stdout(devnull) do … end` — must be able to *save* the current
# stdout and *restore* it afterwards.  `reinit_stdio()` binds the globals to
# real libuv streams, which is exactly what makes that round-trip work: the
# save captures a stream whose `.handle` restore writes back into the C-level
# `jl_uv_stdout`.
#
# Two dead ends worth recording, since both looked plausible:
#   * Leaving the raw `Core.CoreSTDOUT` handle in place makes the *restore*
#     throw `MethodError: (::RedirectStdStream)(::Core.CoreSTDOUT)` — there is
#     no redirect method for the core handle.
#   * Pointing the globals at `devnull` fixes that MethodError but is worse: the
#     DevNull redirect path stores the sentinel `Ptr{Cvoid}(unix_fd)` (i.e.
#     `(void*)1`) into `jl_uv_stdout` (see `_redirect_io_cglobal`), and with
#     stdout==devnull the save/restore re-applies devnull, leaving that sentinel
#     in place.  `generate_precompile.jl` then calls `reinit_stdio()` itself,
#     whose `jl_stdout_stream` returns the sentinel and `init_stdio` derefs
#     `(void*)1->type` → segfault.
# `reinit_stdio()` is a supported, repeatable call (base's generate_precompile
# and test/ccall.jl both use it) and serializes fine: the output image's own
# `Base.__init__` overwrites these globals at startup before anything reads them.
Base.reinit_stdio()
Base.Sys.__init_build()      # Sys.BINDIR + Sys.STDLIB (from JULIA_BINDIR)
Base.init_depot_path()       # DEPOT_PATH (JULIA_DEPOT_PATH or default depot)
Base.init_load_path()        # LOAD_PATH (JULIA_LOAD_PATH, e.g. @:@stdlib)
Base.init_active_project()   # active project (JULIA_PROJECT)

# `--output-o` (non-incremental) mode also skips running each restored
# sysimage module's `__init__`.  The C runtime *defers* it: in this mode
# `jl_init_restored_module` doesn't run the initializer, it only queues the
# module into `jl_module_init_order` so the *output* image runs it at its own
# startup (see src/module.c).  So stdlib modules baked into the base sysimage
# are present but their runtime state is never initialized during the bake.
# The one that bites in practice is LinearAlgebra: its `__init__` forwards the
# BLAS/LAPACK symbols into libblastrampoline (`BLAS.lbt_forward`), and without
# it every BLAS/LAPACK call dispatches through an unbound trampoline entry and
# segfaults (`unknown function (ip: 0x0)`).  A baked package that touches BLAS
# at load time — e.g. Colors evaluates `inv(...)` for a constant matrix at top
# level — crashes the bake before `using` even returns.  (PackageCompiler
# avoids this only because it builds *incremental* images, where the same C
# path runs the initializers instead of deferring them.)
#
# Invoke the restored modules' `__init__`s directly here, bypassing the
# deferring `jl_init_restored_module` — calling the Julia function runs it now
# in the bake process, which is what the precompile workload needs.  The
# deferred queue is untouched, so the output image still re-runs these at its
# own startup (on device, that's where the real BLAS/paths get set up).  Skip
# Core (no `__init__`) and Base (we deliberately don't run `Base.__init__` in
# full here — it starts background threads / signal handlers inappropriate for
# a build process; its loading pieces were already replicated above).
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

    # BLAS is the case that actually bites the bake, and it needs care.  A baked
    # package that calls BLAS at load time (Colors evaluates a top-level `inv`)
    # needs the host BLAS/LAPACK symbols forwarded into libblastrampoline first
    # — that is LinearAlgebra.__init__'s job (`BLAS.lbt_forward(...)`), but only
    # *after* OpenBLAS_jll.__init__ has set `libopenblas_path`.  Two things make
    # a plain restore-order loop unreliable for this:
    #   * restore order isn't guaranteed to run OpenBLAS_jll before
    #     LinearAlgebra, and
    #   * OpenBLAS_jll.__init__ opens `@rpath/libopenblas*.dylib`, which may not
    #     resolve in the bake process; if that throws, `libopenblas_path` is left
    #     "" and `lbt_forward(""; clear=true)` clears the trampoline to a stub
    #     that aborts the process with "Quitting." on the first BLAS call.
    # So drive the chain explicitly and in order, and if the JLL's @rpath open
    # didn't set a path, fall back to the host's bundled OpenBLAS by abs path.
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
        # Report which OpenBLAS the bake forwards (nostdio-safe raw write, since
        # `Base.__init__`/`reinit_stdio` has not run in this mode).
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
