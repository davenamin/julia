# The iOS port: what it changes, relative to `release-1.13`

This tree is upstream `JuliaLang/julia` `release-1.13` plus a port that
cross-compiles Julia for iOS (arm64, device and simulator) as a set of
frameworks an app can embed.  This file is the inventory of that delta, by
area, with the reason for each part, so the port can be understood — and
moved onto a later release — without reading the whole diff.

Related documents:

- `build-xcframework.sh` — how to build; its header lists every option.
- `julia_ios_init.h` — how an app starts the runtime.
- `APPSTORE.md` — what the build does for App Store submission, and what
  each app still has to answer or verify itself.

## How the port works

Three constraints shape everything else.

**Nothing built for iOS runs on the build machine.**  The build is a
cross-compile: `make IOS=1` in an out-of-tree directory builds the runtime and
its dependencies with the iOS SDK, and an ordinary host build in the source
tree supplies the tools that have to run — `flisp`, LLVM's tblgen, and the
`julia` that produces the sysimage.  The host julia loads Base and the stdlibs
as usual and then emits the image's native code for iOS instead of for
itself, using a `--target=<triple>` option the port adds (`sysimage-ios.mk`).

**An app bundle may contain no loose dynamic libraries.**  Each library
ships as its own single-binary framework, the sysimage included
(`contrib/ios/Makefile`), and the runtime maps the unix-style library names
Julia code opens (`libgmp`, `@rpath/libz.1.dylib`) onto that layout
(`src/dlload.c`).

**A device cannot map executable memory or spawn a process.**  So there is
no JIT and no subprocess.  Code baked into the sysimage runs natively;
everything else runs in the interpreter (`--compile=min`), which the port
teaches to make foreign calls through libffi (`src/interpreter-ccall.c`).
The one place the stdlibs depend on a subprocess for ordinary use — Pkg
decompressing archives — gets an in-process implementation.  The simulator
has neither restriction, which matters for what its test results mean; see
[Testing](#testing).

Almost every change is conditional on `IOS=1` in the build or on the
`Base.IOS` constant it bakes.  The exceptions are listed under
[Changes that are not iOS-gated](#changes-that-are-not-ios-gated).

## New files

| Path | Purpose |
|---|---|
| `sysimage-ios.mk` | The cross-targeted sysimage build: the host julia emits an iOS arm64 object via `--target`, which is then linked with the iOS SDK. |
| `src/interpreter-ccall.c` | Foreign calls from interpreted code, through libffi. |
| `deps/libffi.mk`, `deps/libffi.version`, `deps/checksums/libffi-*` | libffi, built for iOS only. |
| `deps/patches/llvm-libunwind-ios-public-dyld-api.patch` | Replaces a private dyld call in libunwind with public API. |
| `deps/tools/objconv-fix-alignment.sh` | Wrapper for the OpenBLAS ILP64 symbol-suffixing step; restores the archive member alignment Apple's linker requires. |
| `stdlib/patches/Pkg-spawn-free-gzip.patch` | In-process gzip decompression for Pkg. |
| `stdlib/patches/LinearAlgebra-ios-accelerate.patch` | Forwards Apple's Accelerate over OpenBLAS on iOS. |
| `contrib/ios/Makefile` | Bundles each built library as its own framework, signs them, generates dSYMs. |
| `contrib/ios/build-xcframework.sh` | Builds both slices, combines them into xcframeworks, stages `julia-runtime-resources/`. |
| `contrib/ios/julia_ios_init.{c,h}` | Embedding helper compiled into the app: sets the depot and load paths, locates the sysimage, initializes the runtime. |
| `contrib/ios/sysimage_env_init.jl` | Preamble for sysimage builds that bake extra code or packages. |
| `contrib/ios/check-host-paths.sh` | Audits shipped artifacts for build-machine paths. |
| `contrib/ios/ci-checks.sh` | Structural checks that need no build; see [Testing](#testing). |
| `contrib/ios/simulator-selftest.c` | Command-line embedder run in the simulator; exercises the interpreted foreign-call path and the BLAS report. |
| `contrib/ios/simulator-runtests.c`, `ios_runtests.jl` | Run Julia's own test suite in the simulator. |
| `contrib/ios/test-gzip-inflate.jl`, `test-accelerate.jl` | Host-side tests of the two stdlib patches. |
| `.github/workflows/ios.yml` | CI. |

## Build system

- `Make.inc` — the `IOS=1` configuration: SDK, architecture and
  deployment-target selection through `xcrun`; `FC := false` and
  `USE_BINARYBUILDER := 0`, since there is no Fortran compiler and there are
  no prebuilt binaries for iOS; host compiler variables (`HOSTCC`,
  `HOST_CFLAGS`, and a `BUILDING_HOST_TOOLS` mode) for the pieces that must
  run on the build machine; a framework-relative `LOADER_BUILD_DEP_LIBS`.
  It also sets three defaults that are shipping decisions rather than
  mechanics:
  - `IOS_VERSION_MIN ?= 16.4`, the first release with Accelerate's ILP64
    interface.
  - `USE_GPL_LIBS ?= 0`, which leaves out the GPL parts of SuiteSparse.
  - `IOS_CPU_TARGET ?= apple-a11`, used for both `-mcpu` and
    `JULIA_CPU_TARGET`.  A cross-build has no host CPU to infer a target
    from, and naming a core lets the compiler emit instructions that older
    devices trap on.  **The app must restrict itself to matching devices**;
    `APPSTORE.md` explains the choice and how to declare it.
- `Makefile` — under `IOS=1`, `julia-release` builds the libraries and then
  the sysimage through `sysimage-ios.mk` (`IOS_SYSIMAGE=0` skips it), and
  builds host-native libuv and utf8proc for the host `flisp`.  Adds
  `ios-framework` / `ios-xcframework` convenience targets.
- `base/Makefile` — writes `const IOS = true|false` into `build_h.jl`.
- `cli/Makefile` — builds the loader library only; iOS has no `julia`
  executable.
- `src/Makefile` — compiles `interpreter-ccall.c`; names the LLVM link
  libraries directly, because the `llvm-config` built for iOS cannot be run
  to ask; links libffi; omits the linker flags that reference private dyld
  symbols.
- `sysimage-ios.mk` — described in the next section.

### The sysimage build

`sysimage-ios.mk` is the iOS counterpart of `sysimage.mk`.  Its stages run
the host julia with the iOS build tree's `build_h.jl`, so the image is built
with `Base.IOS == true`:

1. `basecompiler.ji` and 2. `sysbase.ji` — the compiler, then Base and the
   sysimage stdlibs, as serialized IR.  These stay `.ji` files where
   `sysimage.mk` links native libraries, because a native link in this tree
   is an iOS one and the host julia has to load what it just produced.
3. `sys-o.a` — `--output-o --target=arm64-apple-ios<min>[-simulator]`.
4. `sys.dylib` — linked with the iOS SDK; `contrib/ios/Makefile` ships it as
   `JuliaSysimage.framework`.

Options:

- `IOS_SYSIMAGE_EXTRA_JL`, `IOS_SYSIMAGE_EXTRA_PROJECT` — bake an app's own
  code and (pure-Julia) packages into the image, which is the only way to
  have them run natively on a device.  Such builds load
  `sysimage_env_init.jl` first: an `--output-o` process skips `Base.__init__`
  and defers every module's `__init__`, so the preamble sets up the loading
  environment and runs the initializers the baked code needs at load time.
- `IOS_SYSIMAGE_COMPILE_ALL=1` — also bake a generic, unspecialized compiled
  entry for every method.  A method called with types no baked
  specialization covers then runs native code instead of the interpreter, at
  a substantial cost in image size.  Off by default.

### Dependencies

All dependencies build from source.  The changes are cross-compilation
fixes:

- Host tools are built with the host compiler: objconv, libwhich, GMP's
  `CC_FOR_BUILD`, OpenBLAS's `getarch`, LLVM's native tools.
- CMake dependencies get `CMAKE_SYSTEM_NAME=iOS` and the matching
  `CMAKE_OSX_*` settings (`deps/tools/common.mk`).  LLVM uses its own iOS
  toolchain file and the host build's tblgen, and does not build `sancov`,
  whose source does not compile against current iPhoneOS SDKs.
- LLVM's `HandleLLVMOptions.cmake` passes `-Wl,-z,defs` unless the system
  name is `Darwin`; an iOS build reports `iOS`, and Apple's linker has no
  `-z`.  `llvm-ios-no-z-defs` in `deps/tools/common.mk` adds `iOS` to that
  list in both llvm-project checkouts the build uses — LLVM's own and the one
  libunwind configures through — as an in-place edit, because the line
  differs between their versions.
- libunwind: `llvm-libunwind-ios-public-dyld-api.patch` reimplements
  `_dyld_find_unwind_sections` on `dladdr` and `getsectiondata` for iOS
  targets, because App Store validation rejects references to private
  symbols (ITMS-90338).
- OpenBLAS builds only its `shared` target (the tests cannot link when
  cross-compiling) and, with no Fortran compiler, uses its C LAPACK sources.
- PCRE2 is built without its JIT.
- curl is told `pipe2` is unavailable: the SDK's library stub has the symbol,
  but the header only declares it for newer deployment targets.
- libgit2 names its HTTPS backend (`SecureTransport`) instead of relying on
  autodetection, and is told `getentropy` is unavailable, since the SDK has
  the symbol but not `<sys/random.h>`.
- `CompilerSupportLibraries` is skipped: iOS has no GCC runtime libraries,
  and the rule would copy the host's.
- libffi 3.5.2 is added, built only under `IOS=1` and linked statically into
  `libjulia-internal`, so it costs no extra framework.  It is MIT-licensed.

`deps/tools/stdlib-external.mk` gains a `source-patched` step that applies
`stdlib/patches/<Name>-*.patch` to an external stdlib after extraction.  The
directory is separate from `deps/patches/` because the two namespaces overlap
(`SuiteSparse` is both a dependency and a stdlib).

## Runtime (`src/`)

- `support/platform.h` — defines `_OS_IOS_`, a subset of `_OS_DARWIN_`, from
  `TARGET_OS_IPHONE`.  It is defined for the simulator too.
- `jloptions.{c,h}`, `aotcompile.cpp`, `base/options.jl` — the
  `--target=<triple>` option.  With it, `--output-o` emits its object for
  that triple instead of the host's.  The sysimage build rests on this.
- `dlload.c` — when `dlopen` of a relative library name fails, retry at
  `@loader_path/../<base>.framework/<base>`, where `<base>` is the name with
  `.dylib` and trailing version components removed — the rule
  `contrib/ios/Makefile` names frameworks by.  Absolute paths are not
  remapped.
- `interpreter-ccall.c`, `interpreter.c`, `toplevel.c` — perform
  `:foreigncall` in the interpreter with libffi's `ffi_call`, which needs no
  executable memory.  Julia otherwise forces compilation of any code
  containing a `ccall`; on iOS that requirement is kept only for `@cfunction`,
  which needs a code address C can call and so cannot work without code
  generation.  Types are passed the way codegen passes them, including
  static-parameter substitution, `Ref{T}`, boxed values, structs by value,
  variadic callees and `gc_safe` calls.  `Int128`/`UInt128`, `Float16` and
  `VecElement` vectors have no libffi representation and raise an error
  naming the reason.  Other platforms keep the original behaviour, including
  raising before any argument is evaluated.
- `jitlayers.cpp` — on device builds, raise a Julia error naming the method
  when code generation is attempted, instead of faulting on memory that
  cannot be made executable.
- `processor_arm.cpp` — on iOS, detect CPU features from the
  `hw.optional.arm.FEAT_*` sysctls.  The macOS path assumes at least an M1,
  which is wrong on a phone.  The detected set gates sysimage loading as well
  as multiversioned dispatch, so it includes the architecture-level features
  LLVM models and derives them from the extensions each level mandates.
- `signals-mach.c` — on iOS, the private keymgr and dyld hooks are replaced
  by no-op stand-ins, so the binary references no private symbols.
- `sys.c` — does not include `<sys/ptrace.h>`, which the iOS SDK lacks.
- `gf.c` — under `--compile=min`, a method's baked unspecialized code is used
  in preference to interpreting it; pick an entry that is valid in the
  current world rather than the newest one.  An image built with
  `--compile=all` carries entries inferred during bootstrap that have since
  expired, and running one ends in a trap.  This is what makes
  `IOS_SYSIMAGE_COMPILE_ALL=1` usable.
- `julia.h` — includes `julia_version.h` with quotes, so the header resolves
  beside `julia.h` inside a framework's `Headers/`.

## Standard library

- `CompilerSupportLibraries_jll`, `OpenBLAS_jll` — do not load the GCC
  runtime libraries or libgfortran on iOS, which has neither.
- `stdlib/patches/Pkg-spawn-free-gzip.patch` — Pkg decompresses every archive
  by piping it through a bundled executable.  The patch routes all archive
  reads (`unpack`, `download_verify_unpack`, `verify_archive_tree_hash`,
  `Registry.uncompress_registry`) through one function, `open_tarball`, which
  decompresses gzip in-process with zlib when no process can be spawned, and
  stops Pkg asking servers for zstd in that case.  Creating archives, and
  reading formats other than gzip, still need a subprocess and fail with an
  error that says so.
- `stdlib/patches/LinearAlgebra-ios-accelerate.patch` — adds
  `BLAS.forward_accelerate!` and `BLAS.report`, and forwards Accelerate over
  OpenBLAS when LinearAlgebra loads on iOS.  OpenBLAS remains the complete
  fallback; `APPSTORE.md` covers the details.

Both are patches because Pkg and LinearAlgebra are external stdlibs pinned to
an upstream commit.

## Changes that are not iOS-gated

These take effect on every platform, and are the part of the port an upstream
merge has to look at even if it never builds for iOS:

- `--target`, an added command-line option and `JLOptions` field.
- The `gf.c` world check.
- The `julia.h` include form.
- The external-stdlib patch step, and so the two patches themselves: the Pkg
  in-process path exists everywhere and is selected by `Base.IOS` or
  `JULIA_PKG_NO_SUBPROCESS=1`; `BLAS.forward_accelerate!` and `BLAS.report`
  are defined everywhere and called automatically only under `Base.IOS`.
- Dependency build robustness: `deps/tools/jldownload` retries and removes a
  partial download; GMP is fetched from ftp.gnu.org before gmplib.org; the
  objconv alignment wrapper; host-compiler flags in `CC_FOR_BUILD`-style
  variables, which are empty off iOS.
- The edits to LLVM's and libunwind's sources described above, which are
  applied whenever those are built from source and are inert off iOS.

## Testing

CI is `.github/workflows/ios.yml`, a pipeline rather than independent jobs
because the expensive pieces are shared:

1. **`checks`** runs `contrib/ios/ci-checks.sh` on Linux in seconds, and is
   the thing to run locally before anything else.  It verifies that each
   patch applies to the revision it is pinned to, type-checks the iOS-only
   code (which no other build compiles), and compares the places where the
   iOS build restates something the ordinary build computes.  `macos-checks`
   runs the part that needs the iOS SDK.
2. **`host-build`** builds the host julia on macOS, runs the tests that need
   an executable — the two stdlib patches, the single-process test driver,
   and a `--compile=all` image under `--compile=min` for the `gf.c` change —
   and publishes `usr/` for the iOS jobs, which need it for the sysimage.
3. **`ios-sim`** builds the simulator slice and runs it under `simctl spawn`.
4. **`ios-build`** builds the device slice and checks the artifacts.

The two iOS jobs take hours and are opt-in: start them from the Actions tab,
or put `[run-ios]` in the commit message of a push.

The simulator is the only place iOS-targeted code executes in CI, and what
it shows has a boundary.  It defines `TARGET_OS_IPHONE`, so everything behind
`_OS_IOS_` is live: the libffi foreign calls, the sysctl CPU detection, the
framework `dlopen` fallback, Accelerate forwarding.  But it runs under macOS
rules — the JIT works, `fork`/`exec` succeed, the bundle is writable — so it
cannot show anything caused by a device *restriction*.

Julia's own test suite runs there through `simulator-runtests.c`, which uses
the same embedding API as an app.  There is no command line, so the harness
sets what `test/Makefile` would pass (`--check-bounds=yes`,
`--depwarn=error`, `--startup-file=no`) in `jl_options` and hands the test
selection to `test/choosetests.jl` through `ARGS`.  The resources tree
carries `test/` only when built with `IOS_STAGE_TESTS=1`.  Two drivers:

- **`runtests`** — upstream's `test/runtests.jl`, unmodified, with the JIT
  on.  It spawns worker processes for any selection of more than one test
  set, so it is run once per test name.  Its value is fidelity: the staged
  tree is exercised by the runner upstream ships.
- **`ios`** — `ios_runtests.jl`: one process, every test set in sequence, no
  `Distributed`, under `--compile=min`.  This is the only shape a device
  could run, and it puts every `ccall` in the selected tests through the
  interpreter.  Interpreted tests are orders of magnitude slower, so its
  selection is small.  It reuses `choosetests.jl` for selection and mirrors
  `testdefs.jl`'s per-test isolation; where upstream discards a worker
  process after each test set, this driver restores `DEPOT_PATH`,
  `LOAD_PATH`, `ENV` and the active project itself.

Test sets that need a subprocess (`spawn`, `cmdlineargs`, `precompile`, most
of `loading`) cannot run on iOS and are not part of either selection.

## Known limitations

- Simulator slices are arm64 only (Apple-silicon hosts).
- Code outside the sysimage is interpreted on a device.  It can call C
  through libffi, but `@cfunction` cannot work, and `Int128`/`UInt128`,
  `Float16` and SIMD vectors cannot cross a foreign call.
- Only pure-Julia packages can be baked into the sysimage.  A package with a
  binary (`_jll`) dependency needs that library built for iOS and shipped as
  a framework, which nothing here automates.
- Packages outside the sysimage load from source.  Writing a precompile
  cache needs a subprocess, so `julia_ios_init_with_paths` restricts loading
  to cache files that already exist; none are shipped, and the stdlibs
  outside the sysimage (Test, Printf, Dates, …) load from source too.
- Pkg can read gzip archives but not zstd ones.  It does not request zstd
  from servers on iOS, but a registry or artifact copied into the bundle as
  `.tar.zst` from a desktop depot will not be readable; ship it unpacked or
  as `.tar.gz`.
- Sparse factorizations are absent, following `USE_GPL_LIBS = 0`.
- The sysimage contains the build tree's absolute paths for the source files
  it was built from; Julia records those by design and rewrites them only
  for display.  Build from a directory with no username in it if that
  matters; `check-host-paths.sh` reports what is there.

## Moving to a later release

The port is a short series of commits on top of the upstream branch, one per
area in the order of this file.  To move it:

1. Rebase onto the new base and run `contrib/ios/ci-checks.sh`.  It reports
   patches that no longer apply and iOS-only code that no longer compiles,
   which are the two things a rebase does not flag as conflicts.
2. Re-anchor a failing stdlib patch against the commit the new base pins in
   `stdlib/<Name>.version`.
3. Compare `sysimage-ios.mk` with the new `sysimage.mk` for added stages or
   flags, and `LOADER_BUILD_DEP_LIBS` in `Make.inc` with the generic
   definition above it.
4. Push with `[run-ios]`: the dependency builds are cached on the contents
   of `deps/` and `Make.inc`, so the first run after a rebase rebuilds LLVM
   for both slices.
