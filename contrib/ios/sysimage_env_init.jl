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
# Re-run exactly the loading-init steps `Base.__init__` performs, honoring the
# JULIA_* environment the bake already sets, so the extra project's packages
# resolve and load.  These are no-ops for a bake with no extra packages.
Base.Sys.__init_build()      # Sys.BINDIR + Sys.STDLIB (from JULIA_BINDIR)
Base.init_depot_path()       # DEPOT_PATH (JULIA_DEPOT_PATH or default depot)
Base.init_load_path()        # LOAD_PATH (JULIA_LOAD_PATH, e.g. @:@stdlib)
Base.init_active_project()   # active project (JULIA_PROJECT)
nothing
