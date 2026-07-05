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

# `--output-o` mode also skips the runtime pass that runs each sysimage
# module's `__init__` (the C runtime does this during a normal `jl_init`,
# right after restoring the image).  So stdlib modules baked into the base
# sysimage are present but their runtime state is never initialized.  The one
# that bites in practice is LinearAlgebra: its `__init__` forwards the BLAS /
# LAPACK symbols into libblastrampoline (`BLAS.lbt_forward`), and without it
# every BLAS/LAPACK call dispatches through an unbound trampoline entry and
# segfaults (`unknown function (ip: 0x0)`).  A baked package that touches BLAS
# at load time — e.g. Colors evaluates `inv(...)` for a constant matrix at
# top level — crashes the bake before `using` even returns.
#
# Re-run the initializers for the already-restored sysimage modules, in load
# order, exactly as the runtime would.  Modules loaded *fresh* by an EXTRA_JL
# `using` self-initialize via the loader, so this only needs to cover the ones
# already in the image.  Skip Core and Base: Core has no `__init__`, and we
# deliberately do not run `Base.__init__` in full here (it starts background
# threads / signal handlers inappropriate for a build process) — its loading
# pieces were already replicated above.
for mod in Base.loaded_modules_array()
    (mod === Core || mod === Base) && continue
    if isdefined(mod, :__init__)
        try
            Base.run_module_init(mod)
        catch ex
            Base.showerror_nostdio(ex, "WARNING: Error initializing $(nameof(mod)) in sysimage bake")
        end
    end
end
nothing
