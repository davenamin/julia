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
# own startup (on device, that's where the real BLAS/paths get set up).
# Only the modules already in the base image need this: they're the ones live
# at preamble time, and one of them (LinearAlgebra) must have forwarded BLAS
# before the workload's `using` evaluates a package body that calls into it at
# top level (Colors' `inv`).  Skip Core (no `__init__`) and Base (we
# deliberately don't run `Base.__init__` in full here
# — it starts background threads / signal handlers inappropriate for a build
# process; its loading pieces were already replicated above).
for mod in Base.loaded_modules_array()
    (mod === Core || mod === Base) && continue
    isdefined(mod, :__init__) || continue
    try
        Base.invokelatest(getglobal(mod, :__init__))
    catch ex
        Base.showerror_nostdio(ex, "WARNING: Error initializing $(nameof(mod)) in sysimage bake")
    end
end
nothing
