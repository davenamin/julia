# What this fork changes, relative to `release-1.12`

An inventory of the delta from upstream `JuliaLang/julia` `release-1.12`,
grouped by area, so a rebase onto a later 1.12.x can be planned without
reading the whole diff.  For the App Store consequences of these changes,
see `APPSTORE.md`; for how to build, see the header of `build-xcframework.sh`.

Everything here is gated on `IOS=1` or on the `Base.IOS` constant it bakes,
with three deliberate exceptions: the dependency build fixes; the JLL
library-path fix, an upstream bug that happens to bite hardest here; and
`BLAS.forward_accelerate!` / `BLAS.report`, defined on every platform but
only called automatically under `Base.IOS`.

CI lives in `.github/workflows/ios.yml`, as a pipeline rather than parallel
tiers, because the expensive pieces are shared.  `checks` runs
`contrib/ios/ci-checks.sh` in seconds on every push (also runnable locally,
and the thing to run first).  `host-build` then builds the host julia, runs
the tests that need a REPL, and publishes `usr/` as an artifact — both iOS
jobs need a host julia for the sysimage bake, so it is the producer, not a
parallel stage.  `ios-sim` and `ios-build` restore that artifact instead of
building their own, and cache the installed iOS dependency prefix on a key
covering only what the dependency build reads, so ordinary `src/` iteration
keeps hitting it.

`ios-sim` is the only stage that *runs* iOS-targeted code: the simulator
defines `TARGET_OS_IPHONE`, so the libffi ccall interpreter, the sysctl CPU
detection and the framework `dlopen` fallback are all live, and
`contrib/ios/simulator-selftest.c` drives them under `simctl spawn`.  It
cannot show anything caused by a device *restriction* rather than by iOS
code: the JIT works there, `fork`/`exec` succeed and the bundle is writable.

Conventions for work on this branch:

- One topical commit per change, and each commit builds on its own.
- History is not rewritten once pushed, so a later fix is its own commit
  rather than a fold-in.
- Comments describe the design as it stands and why it is that way, without
  narrating the change that produced it.

## New files

| Path | Purpose |
|---|---|
| `contrib/ios/Makefile` | Bundles each built dylib as its own single-binary framework, signs them, generates dSYMs. |
| `contrib/ios/build-xcframework.sh` | Drives both slices (device + simulator), combines them into xcframeworks, stages `julia-runtime-resources/`. |
| `contrib/ios/julia_ios_init.{c,h}` | Embedding helper for the app target: sets `JULIA_BINDIR`/depot/load-path, locates the sysimage, calls `jl_init_with_image`. |
| `contrib/ios/sysimage_env_init.jl` | Preamble for the sysimage bake — re-runs the loading init and module `__init__`s that `--output-o` mode skips. |
| `contrib/ios/check-host-paths.sh` | Audits shipped artifacts for build-machine absolute paths. |
| `contrib/ios/test-gzip-inflate.jl` | Compares Pkg's in-process gzip path against the `7z` path. |
| `contrib/ios/test-accelerate.jl` | Compares the Accelerate and OpenBLAS backends, and reports Accelerate's LAPACK coverage. |
| `contrib/ios/APPSTORE.md` | Submission notes: frameworks layout, privacy manifests, export compliance, GPL, BLAS. |
| `sysimage-ios.mk` | Cross-targeted sysimage bake: host julia emits an iOS arm64 object via `--target`, then links it with the iOS SDK. |
| `stdlib/patches/Pkg-spawn-free-gzip.patch` | Applied to the vendored Pkg checkout at extraction (see below). |
| `deps/libffi.mk`, `deps/libffi.version` | libffi, built for iOS only — the interpreter makes foreign calls through it. |
| `deps/patches/llvm-ios-*.patch`, `llvm-libunwind-ios-public-dyld-api.patch` | iOS build fixes for LLVM and libunwind. |
| `deps/tools/objconv-fix-alignment.sh` | Host-tool wrapper for the OpenBLAS ILP64 symbol-suffixing step. |

## Runtime (`src/`, `cli/`)

- `src/support/platform.h`, `src/sys.c` — define `_OS_IOS_` as a subset of
  `_OS_DARWIN_`, keyed on `TARGET_OS_IPHONE`.
- `src/jloptions.{c,h}`, `src/aotcompile.cpp`, `base/options.jl` — add
  `--target=<triple>` so `--output-o` cross-emits an iOS arm64 object from a
  macOS host.  This is the mechanism the whole sysimage bake rests on.
- `src/dlload.c` — iOS-only fallback: a failed `dlopen` of a unix-style dylib
  name (`libgmp`, `@rpath/libz.1.dylib`) is retried at
  `@loader_path/../<base>.framework/<base>`, applying the same name-stripping
  rule `contrib/ios/Makefile` used when bundling.  Absolute paths are excluded.
- `src/jitlayers.cpp` — fail with a named error when codegen is attempted on
  a device, instead of faulting on unmappable executable memory.
- `src/processor_arm.cpp` — detect the device's extensions from the
  `hw.optional.arm.FEAT_*` sysctls on iOS.  The Darwin/aarch64 path reports an
  M1 for anything it does not recognise, which is a safe floor on a Mac and
  wrong on a phone; left as it was for macOS.  This gates image loading, not
  just multiversioned dispatch: the loader derives the disabled feature set as
  the complement of the detected one and refuses any image target that enables
  a bit outside it, so the detected set has to include the architecture-level
  markers LLVM models as features and every leaf the `apple-*` masks name,
  neither of which a sysctl reports directly.
- `src/interpreter-ccall.c` (new), `src/interpreter.c`, `src/toplevel.c` —
  perform `:foreigncall` in the interpreter instead of requiring codegen, **on
  iOS builds only**, using libffi's `ffi_call`.  Dispatching to an existing
  function pointer needs no executable memory; only the reverse direction
  (`ffi_prep_closure_loc`, which is what `@cfunction` would need) does, so that
  stays unsupported everywhere.  Reaching the interpreter at all also needed
  two changes in `toplevel.c`.  Julia forces codegen for any code containing a
  `ccall`, at both the thunk and the method-dispatch decision, so `@cfunction`
  is now distinguished from `ccall` and only the former forces it.  And a
  top-level thunk now gets `jl_resolve_globals_in_ir` on the interpreter path:
  a `:foreigncall` holds its return and argument types as unevaluated
  expressions until that pass runs, and previously only the codegen path — which
  every `ccall` thunk took — ever ran it.  Supported: void, integers and floats
  up to 64 bits, pointers, boxed Julia values (`Any`, `String`, `Vector{T}`,
  any mutable struct — codegen hands C the `jl_value_t*` and so does this), and
  isbits structs and tuples by value, in registers or on the stack or through a
  hidden return pointer as the ABI dictates; `Ref{T}`, substituted the way
  codegen substitutes it (`Ptr{Cvoid}` for an argument, `Any` for a return);
  any number of arguments; and variadic callees, via `ffi_prep_cif_var`.  Not supported, each rejected with
  a message naming the reason: `Int128`/`UInt128` and `Float16`, for which
  libffi has no type, and `VecElement` vectors.  Non-iOS builds are unchanged,
  including raising before any argument is evaluated.

- `src/jlapi.c`, `src/julia.h`, `src/julia_internal.h` — embedding surface for
  `jl_init_with_image`.
- `src/signals-mach.c` — drop references to private dyld API, which App Store
  validation rejects (ITMS-90338).

## Build system

- `Make.inc` — the iOS block: SDK/arch/deployment-target selection,
  `FC := false`, `EXE :=`, framework-aware loader deps.  Three defaults
  specific to shipping: `IOS_VERSION_MIN ?= 16.4`, `USE_GPL_LIBS ?= 0`, and
  `IOS_CPU_TARGET ?= apple-a11`, driving both `-mcpu` and
  `JULIA_CPU_TARGET`.  A cross-build has no host CPU to infer from, and
  naming a core emits instructions older devices trap on rather than
  degrading.  A11 is where the cliff is: ordinary numeric code compiles
  identically from a7 to a13, but a7 loses LSE atomics (2-3x the
  instructions, taxing GC, locks and task switching) and hardware Float16
  (3x).  Above a11 only SHA3 is left, worth ~9% on Random's SIMD generator.
  **The app must declare a matching minimum device** — `IOS_VERSION_MIN =
  16.4` admits A9 iPads by itself.
- `Makefile`, `base/Makefile`, `cli/Makefile`, `src/Makefile` — route host
  tools during cross-compilation; bake `Base.IOS` into `build_h.jl`.
- `deps/*.mk` — cross-compile fixes (host-tool routing, Xcode 26 SDK).
- `deps/libgit2.mk` — `-DUSE_HTTPS=SecureTransport` on iOS, so certificates are
  validated against the device's trust store.  libgit2 1.9.0 does find
  Security.framework under a cmake iOS build on its own; naming the backend
  keeps a future autodetection change from silently selecting one that needs
  a CA bundle, since `NetworkOptions.ca_roots()` returns nothing on Apple
  platforms on the assumption that the system store is in use.  libcurl was
  already correct: `deps/curl.mk` selects `--with-secure-transport` for
  `OS = Darwin`, which iOS builds are.
- `deps/tools/stdlib-external.mk` — a `source-patched` step for vendored
  stdlibs, applying `stdlib/patches/<name>-*.patch` after extraction.  Kept
  separate from `deps/patches/` because the two namespaces collide
  (`SuiteSparse` is both a dep and an stdlib).

### Dependencies

`release-1.12` already ships the versions this port needed on 1.10
(blastrampoline 5.15.0, GMP 6.3.0, MPFR 4.2.2, OpenLibm 0.8.7, zlib 1.3.1),
so no bumps remain — only the iOS build fixes that travelled with them.

A new dependency, libffi 3.5.2, is built **only** under `IOS=1` and linked
statically into `libjulia-internal`: an App Store bundle may not contain loose
dylibs, so a shared library would cost another framework for a single
consumer.  It is MIT-licensed, so it does not disturb `USE_GPL_LIBS = 0`.

Three LLVM-side patches are iOS-only and are re-anchored to whatever LLVM the
base ships (18.1.7 here, libunwind 19.1.4): `llvm-ios-no-z-defs` (ld64 has no
`-z`), `llvm-ios-sancov-libcxx-string-init` (a libc++ brace-init rejection in
the iPhoneOS 26 SDK) and `llvm-libunwind-ios-public-dyld-api` (ITMS-90338).

libffi is not in `cache.julialang.org`, which only holds what upstream CI
itself fetched, so it is downloaded from its upstream mirror on a clean build
and a slow mirror shows up as a timeout rather than a compile error.  See the
troubleshooting notes in the header of `build-xcframework.sh`.

## Base

Nothing outside the stdlib JLLs; see below.

## Standard library

- `stdlib/*_jll/src/*.jl` (22 files) — `empty!` the
  `PATH_list` / `LIBPATH_list` arrays at the top of `__init__`.  These are
  serialized into the sysimage with the build machine's paths already in
  them, so appending left stale entries in front of the runtime ones
  forever.  **This is an upstream bug, not iOS-specific**: any sysimage baked
  in a build tree and run from an install tree accumulates the same way.
- `stdlib/CompilerSupportLibraries_jll`, `stdlib/OpenBLAS_jll` — skip
  libgfortran on iOS, which has none.
- `stdlib/patches/LinearAlgebra-ios-accelerate.patch` — forward Apple's
  Accelerate over the OpenBLAS base on iOS, plus `BLAS.report()`.
  LinearAlgebra is an external stdlib as of 1.12, so this is a patch against
  the fetched checkout rather than an in-tree edit.  A
  performance layer: `FC := false` makes OpenBLAS build `NOFORTRAN`, which
  selects its `C_LAPACK` sources rather than dropping LAPACK, so the
  factorizations work without Accelerate too.  Since libblastrampoline
  resolves each symbol to the last library forwarded that has it, Accelerate
  shadows OpenBLAS wherever it exports a symbol.
- `stdlib/patches/Pkg-spawn-free-gzip.patch` — gives `Pkg.PlatformEngines` an
  in-process zlib inflate stream, because iOS forbids `fork`/`exec` and Pkg
  decompresses by piping through the `7z` executable.  Covers all four read
  paths: `unpack`, `download_verify_unpack`, `verify_archive_tree_hash` and
  `Registry.uncompress_registry` — the last in `src/Registry/`, not
  `PlatformEngines`, and the first one an offline depot reaches, since
  registries are themselves `.tar.gz`.  Delivered as a patch because
  `stdlib/Pkg.version` pins an upstream commit.

## Known limitations

- Simulator slices are arm64 only (Apple-silicon hosts).
- Only pure-Julia packages bake into the sysimage; `_jll` packages need
  iOS-built artifacts, which nothing produces.
- Non-baked code is interpreter-only on device (`--compile=min`).  It can make
  C calls of essentially any shape through libffi, but `@cfunction` needs the
  compiler and always will, and `Int128`/`UInt128`, `Float16` and SIMD vectors
  have no libffi representation.
- Sparse factorizations are absent, following `USE_GPL_LIBS = 0`.
- The sysimage still contains the build tree's absolute paths for stdlib
  sources — Julia records those by design (`Sys.BUILD_STDLIB_PATH`) and
  rewrites them only for display.  Build from a directory with no username
  in it if that matters; `check-host-paths.sh` reports what is there.
