# App Store submission notes for the Julia iOS port

What the build does for you, and what you still have to answer or verify
per-app when submitting to App Store Connect.

## Frameworks layout (done by the build)

Apps may not contain loose dylibs or symlinks — every dynamic library ships
as its own single-binary framework under `Frameworks/` (see the top of
`contrib/ios/Makefile`).  `build-xcframework.sh` emits one `.xcframework`
per framework into `<output-dir>/xcframeworks/`.  In Xcode, **Embed & Sign
every xcframework**; link only `Julia.xcframework` (the one with headers).

## Privacy manifests (done by the build)

Since May 2024, Apple requires a `PrivacyInfo.xcprivacy` privacy manifest
declaring any use of "required reason" APIs, for the app and each embedded
framework (missing declarations arrive as ITMS-91053 mails and eventually
block submission).  The build stamps a manifest into every framework
declaring the three categories the Julia runtime actually uses:

| Category | Reason code | Where Julia uses it |
|---|---|---|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | `stat`/`lstat` throughout `base/stat.jl`, on files inside the app container (depot, resources tree) |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` | `Base.diskstat` → `uv_fs_statfs` (`base/file.jl`), checking space before writes |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `Sys.uptime` → `uv_uptime` (`base/sysinfo.jl`) and mach-time clocks, measuring elapsed time in-process |

The manifests declare `NSPrivacyTracking = false` and no collected data —
the runtime phones nothing home.  **Your app's own code** (and any Swift
SDKs you add) may use more categories, e.g. `UserDefaults`; declare those
in the app target's own `PrivacyInfo.xcprivacy` — the manifests aggregate.

## Crash symbolication — dSYMs (done by the build)

App Store Connect wants a dSYM for every embedded binary UUID; otherwise
each upload emits a per-framework "Upload Symbols Failed / The archive did
not include a dSYM for the <name>.framework" warning (non-blocking, but
crash reports for those frameworks stay unsymbolicated).  The build runs
`dsymutil` over every framework binary (the `dsyms` step in
`contrib/ios/Makefile`) and `build-xcframework.sh` embeds the results into
each xcframework via `xcodebuild -create-xcframework -debug-symbols` —
Xcode then copies them into your app archive automatically, and the
warnings disappear.  Frameworks built without debug info yield small,
UUID-matched dSYMs, which still satisfies the check and provides function
names.

## Export compliance questionnaire (you answer this)

*This is practical guidance, not legal advice.*

The framework set bundles real cryptography: OpenSSL (TLS for libcurl) and
libssh2 (SSH for LibGit2).  For the App Store Connect
questions:

- **"Is your app designed to use cryptography or does it contain or
  incorporate cryptography?"** — **Yes.** (Bundled OpenSSL/libssh2 count
  even if your app never opens a connection.)
- **"Does your app qualify for any of the exemptions provided in Category 5,
  Part 2 of the U.S. Export Administration Regulations?"** — **Yes**, for
  the encryption this port ships: it is limited to *standard* algorithms
  and protocols (TLS, SSH) used for data-in-transit, which falls under the
  mass-market / standard-cryptography exemptions.  Equivalently you may set
  `ITSAppUsesNonExemptEncryption = false` in the app's Info.plist to skip
  the questions on every upload.
- These answers hold **only** while the app adds no proprietary or
  non-standard cryptography of its own.  If your app implements custom
  crypto, re-answer accordingly.

Housekeeping that typically accompanies the exemption: the annual
**self-classification report** to BIS/NSA for mass-market encryption, and
the **French import declaration** if you distribute in France.  Whether
these apply to you depends on your distribution posture — check with
counsel once.

## Executing code (Guidelines 2.5.2 / 2.1 — built-in guardrails)

- Apps may not download and execute code.  Interpreting code *bundled with
  the app* or *typed by the user* is established practice; fetching a
  package from the network and running it is not.  Since the port ships
  Pkg's networking stack and supports a writable depot,
  `julia_ios_set_paths` defaults **`JULIA_PKG_OFFLINE=true`** as a
  guardrail — `Pkg.resolve` / `Pkg.instantiate` keep working against the
  bundled depot.  Don't expose network package installation in a shipped
  app.  (Opt out for dev builds by setting `JULIA_PKG_OFFLINE=false` in the
  environment before calling the init helper.)
- iOS forbids JIT compilation in third-party apps, and a crash during
  review is a Guideline 2.1 rejection.  On physical devices
  `julia_ios_init_with_paths` therefore defaults to **interpreter
  fallback**: sysimage-baked code runs natively, anything else interprets
  instead of crashing.  `julia_ios_enable_jit()` opts out (development
  side-loading only — never ship it).  The simulator keeps the JIT.

## Archives without a subprocess (done by the build)

iOS forbids `fork`/`exec` for third-party apps, and Pkg decompresses every
archive by piping it through a bundled executable (`7z`, or `zstd`).  On a
device that spawn fails with `EPERM`, which would stop any Pkg operation that
reads a tarball — including reading the registry, which is itself stored
compressed, so even a fully offline depot would be affected.

`stdlib/patches/Pkg-spawn-free-gzip.patch` (applied to the pinned Pkg checkout
at extraction time — see `deps/tools/stdlib-external.mk`) routes every archive
read in Pkg through one function, `PlatformEngines.open_tarball`.  When
`Base.IOS` is true it inflates gzip with zlib inside the process
(`GzipInflateStream <: IO`) instead of spawning, and Pkg does not ask package
servers for zstd.  Desktop builds keep the subprocess path;
`JULIA_PKG_NO_SUBPROCESS=1` selects the in-process one anywhere, which is how
`contrib/ios/test-gzip-inflate.jl` compares the two implementations on a Mac:

```
usr/bin/julia contrib/ios/test-gzip-inflate.jl
```

Its limits:

- **Only gzip is read in-process.**  A `.tar.zst` registry or artifact — which
  is what a desktop depot holds for anything a package server delivered —
  raises an error naming the format.  Ship bundled registries unpacked or as
  `.tar.gz`.
- **Compression is not implemented.**  `PlatformEngines.package` needs a
  subprocess and says so.  Only archive *creation* calls it, which nothing on
  a device does.
- **This does not make runtime `Pkg.add` shippable.**  Guideline 2.5.2 still
  forbids downloading and executing code, and `julia_ios_set_paths` still
  defaults `JULIA_PKG_OFFLINE=true`.  The patch is what lets operations
  against the bundled depot work.
- **Packages with binary (`_jll`) dependencies still do not work.**  An
  artifact tarball can be unpacked, but the libraries inside it are
  host-macOS binaries and the app bundle may not contain loose dylibs
  anyway.  Only pure-Julia packages baked into the sysimage run natively.
- **Nothing outside the sysimage gets compiled.**  Device builds run under
  `--compile=min`; unpacking a package's source makes it loadable, not fast.
- **`Pkg.build`, `Pkg.test` and `Pkg.precompile` still spawn.**  They launch
  `Base.julia_cmd()` workers, which in-process decompression does not help;
  the embedding helper sets `JULIA_PKG_PRECOMPILE_AUTO=0` so automatic
  precompilation does not fire.  `GitTools` shells out only under
  `use_cli_git()`, which is opt-in — the default LibGit2 path is a library
  call.

## No GPL code in the bundle (done by the build)

`Make.inc` defaults **`USE_GPL_LIBS = 0` when `IOS=1`**.  The SuiteSparse
components Julia uses for sparse factorizations — CHOLMOD, UMFPACK, SPQR —
are GPL, whose terms cannot be met under the App Store's distribution
model.  With this off, `libsuitesparse` is never built, its libraries are
dropped from `JL_PRIVATE_LIBS` (so no SuiteSparse frameworks are emitted),
`Base.USE_GPL_LIBS` is baked `false`, and SparseArrays' `include`s of
`solvers/{umfpack,cholmod,spqr}.jl` are guarded on that constant — so this
is a configuration upstream supports, not a hole punched in the build.
`SuiteSparse_jll.__init__` gates only the GPL group (CHOLMOD, RBio, SPQR,
UMFPACK); it would still `dlopen` the BSD-3 ordering libraries and the LGPL
KLU group, but with `libsuitesparse` never built there is nothing to open.

What it costs on device: **sparse** `lu`, `cholesky`, `qr` and `\`.  Dense
linear algebra is unaffected (that is BLAS/LAPACK, below).  Override with
`make IOS=1 USE_GPL_LIBS=1 …` for a non-App-Store build.

It does **not** remove GMP or MPFR — `BigInt`/`BigFloat` — which are LGPL,
not GPL.  Shipping those depends on this build's one-dylib-per-framework
layout keeping them dynamically linked and therefore replaceable; do not
switch them to static linking without taking advice.

## BLAS and LAPACK — Apple Accelerate (done by the build)

The iOS OpenBLAS **does** have LAPACK.  `Make.inc` sets `FC := false` for
iOS, so OpenBLAS's Fortran probe fails and it is built `NOFORTRAN` — but
OpenBLAS answers that by setting `C_LAPACK=1` and building LAPACK from the
f2c-translated C sources; it sets `NO_LAPACK` only under `ONLY_CBLAS=1`,
which this build does not use.  With Accelerate disabled, every LAPACK
symbol `BLAS.report()` lists is backed by `libopenblas64_`.

Apple's Accelerate framework is forwarded on top of it as a **performance**
layer, when LinearAlgebra loads:

```julia
BLAS.lbt_forward(OpenBLAS_jll.libopenblas_path; clear=true)   # base
BLAS.forward_accelerate!()                                    # layered over it
```

The order is load-bearing.  libblastrampoline resolves each symbol to the
**last** library forwarded that has it, so Accelerate wins where it has a
symbol and OpenBLAS backs the rest.  On a current macOS/iOS that means
Accelerate covers everything `BLAS.report()` probes and OpenBLAS backs
nothing of it — the LAPACK behind the dense factorizations is Apple's.
`JULIA_NO_ACCELERATE=1` turns the forward off and leaves the OpenBLAS-only
configuration, which is fully functional; `LAPACK.version()` says which
implementation is live.

The hint passed to `lbt_forward` is `"\x1a$NEWLAPACK$ILP64"`, and the
leading `\x1a` is not decoration.  Apple drops the F77 trailing underscore
when decorating (`dgemm_` becomes `dgemm$NEWLAPACK$ILP64`), and that byte is how libblastrampoline is told to strip it.
Without it the hint matches nothing, the suffix search falls through to the
undecorated symbols, and Accelerate is forwarded as legacy LP64 — which an
ILP64 Julia cannot call, so it sits in the configuration backing nothing
while reporting a healthy symbol count.

Consequences worth knowing:

- **Deployment target is iOS 16.4.**  Accelerate's ILP64 BLAS/LAPACK is
  exposed under the `$NEWLAPACK$ILP64` symbol suffix, which exists from iOS
  16.4 / macOS 13.3.  The undecorated symbols are LP64, and `BLAS.check()`
  calls `exit()` when no ILP64 library is loaded — so this is a requirement,
  not a preference.  `Make.inc` and `build-xcframework.sh` both default to
  16.4.
- **Accelerate costs nothing in app size** — it is a public system framework
  in the dyld shared cache, needs no entitlement, and is not embedded.
  OpenBLAS is still shipped, as the fallback layer.
- **Check what actually happened on device.**  Call `julia_ios_blas_report()`
  (see `julia_ios_init.h`) or `LinearAlgebra.BLAS.report()`; either prints
  the loaded libraries, the backing library for a spread of BLAS and LAPACK
  symbols, and the live `LAPACK.version()`.  `JULIA_BLAS_REPORT=1` prints it
  at startup.  A symbol reported `UNBOUND` will abort the process if anything
  calls it.  A correct configuration lists Accelerate with `interface=ilp64
  suffix="\x1a$NEWLAPACK$ILP64"`, backing every symbol in the report.
- **Measure it before trusting it.**  On a Mac,
  `usr/bin/julia contrib/ios/test-accelerate.jl` forwards both ways against
  the same Accelerate the device uses, prints which symbols Accelerate
  covers versus which fall back, and checks the numerics agree with
  OpenBLAS.  Anything in its fallback list stays on OpenBLAS on device too.
- `JULIA_NO_ACCELERATE=1` skips the forward, for A/B measurement on the same
  device.

## TLS and certificate trust (done by the build)

Both HTTPS stacks validate against the **device's trust store** — the
Keychain, including any roots an MDM profile has installed — rather than a
CA bundle frozen at build time.

| Stack | Backend | Roots |
|---|---|---|
| libcurl (`Downloads`, and Pkg through it) | OpenSSL, verifying with Apple SecTrust | system trust store |
| libgit2 (`LibGit2`, git over HTTPS) | Secure Transport | system trust store |

curl gets there on its own: `deps/curl.mk` configures
`--with-openssl --with-apple-sectrust` for `OS = Darwin`, and an iOS build is
one.  OpenSSL does the TLS; the certificate chain is handed to the system for
the trust decision.  `NetworkOptions.ca_roots()` returns `nothing` on Apple
platforms, so no CA file is supplied.

libgit2 autodetects its HTTPS backend and prefers Secure Transport.
`deps/libgit2.mk` names the backend explicitly anyway, so a change in that
autodetection is a configure error rather than a silent fallback to a backend
that needs a CA bundle nothing supplies.

Two consequences worth knowing:

- **Do not set `JULIA_SSL_CA_ROOTS_PATH` on iOS.**  A supplied CA file takes
  the place of the system's trust evaluation, so pointing it at a PEM gives
  up the device's trust store — MDM-installed roots included — for a list
  frozen at build time.
- **None of this goes through App Transport Security.**  ATS governs
  `NSURLSession` and `WKWebView`, not BSD sockets, so libcurl bypasses it.
  That is permitted and needs no Info.plist exception, but the app does not
  get ATS's TLS-version and cipher floors, and a plain `http://` URL fetched
  from Julia will simply work.  If that matters, the enforcement has to be
  yours.

Secure Transport is deprecated by Apple (since iOS 13).  libgit2 still
supports it; if a future libgit2 drops it, the replacement has to be chosen
with the same question in mind — where the roots come from.

## Foreign calls from interpreted code (done by the build)

Device builds run everything outside the sysimage in the interpreter.
Upstream's interpreter cannot make a `ccall` — it requires the compiler —
so on iOS the call is performed through libffi's `ffi_call`
(`src/interpreter-ccall.c`), which assembles the arguments and branches to
the callee without writing any code.  Only
`ffi_prep_closure_loc` needs executable memory, and that is the direction
`@cfunction` would need — handing C a pointer back into Julia — so that stays
unsupported.

libffi is built for **iOS only** (`deps/libffi.mk`) and linked statically into
`libjulia-internal`, so it adds no framework to the bundle.  It is
MIT-licensed and does not affect the `USE_GPL_LIBS = 0` default or the export
compliance answers above — it contains no cryptography.

What works, and what does not:

| | |
|---|---|
| integers and floats up to 64 bits, pointers, `Cstring` | yes |
| boxed Julia values — `Any`, `String`, `Vector{T}`, mutable structs | yes, passed as the `jl_value_t*` codegen would pass |
| `Ref{T}`, as an argument or a return type | yes — substituted the way codegen substitutes it, `Ptr{Cvoid}` in and `Any` out |
| isbits structs and tuples by value, and returned by value | yes, at any size — registers, stack, or hidden return pointer as the ABI dictates |
| any number of arguments | yes, spilling to the stack |
| variadic callees | yes, but the signature must declare them |
| `Int128` / `UInt128`, `Float16` | **no** — libffi has no type for these |
| `VecElement` / SIMD vectors | **no** |
| `@cfunction` | **no**, and cannot be made to work without executable memory |

Each unsupported case raises a message naming the reason, rather than passing
arguments incorrectly.

**Declare variadic arguments as variadic.**  Use the `;` form, which sets the
count of fixed arguments:

```julia
@ccall snprintf(buf::Ptr{UInt8}, n::Csize_t, "%d"::Cstring; 42::Cint)::Cint
```

Listing them as though they were fixed happens to work on many ABIs and does
**not** work here: Apple's arm64 ABI passes variadic arguments on the stack,
so a fixed declaration puts them in registers and the callee reads garbage.
This is a property of the platform, not of the interpreter — the same
declaration is equally wrong in compiled code.

Two ways to check it:

1. **Simulator.**  Build the simulator slice and call
   `julia_ios_set_interpreter_fallback()` before init, so the simulator takes
   the interpreted path rather than its (working) JIT, then call
   `julia_ios_ccall_selftest()`.

2. **Device.**  Call `julia_ios_ccall_selftest()` after
   `julia_ios_init_with_paths()`.  It prints one line per case to stderr,
   visible in the Xcode console, and returns the number of failures.  The
   cases are evaluated from source at runtime, so they cannot be running
   compiled from the sysimage.  Expect:

   ```
   julia_ios_ccall_selftest: compile_enabled=3 (3 = min, interpreter fallback)
     abs(-5)            -> 5
     ...
     cabs(3+4im)        -> 5.0
     ldiv(17, 5)        -> (3, 2)
     snprintf varargs   -> "42 2.50"
   julia_ios_ccall_selftest: 14/14 cases passed
   ```

   Each case catches its own error, so a signature the interpreter cannot
   marshal prints the reason and the remaining cases still run.  CI runs
   this in the simulator on every iOS build; a device run is the check that
   the same holds under the device's restrictions.

This is limited to iOS.  Desktop builds keep the original behaviour, so
`--compile=min` there still reports that `ccall` requires the compiler.

## Which devices the binary runs on (match this to your App Store listing)

A cross-build has no host CPU to infer a target from, so one is named:
`IOS_CPU_TARGET`, defaulting to **`apple-a11`** — iPhone 8, iPhone X.  It
sets both `-mcpu` for the C/C++ sources and `JULIA_CPU_TARGET` for the
sysimage.

This is not a tuning choice.  Naming a core lets the compiler use
instructions that core has and older ones lack, and those **fault as
undefined** rather than degrading.  A sysimage built for `apple-m1` crashes
inside `rand` on an A12, for example: `apple-a13` and up carry the SHA3
extension, and LLVM builds `EOR3`/`XAR` from it for the xor-and-rotate shape
Random's SIMD generator is made of.

A11 is the default because that is where the difference actually lives.
Compiling float/int conversions, reductions, dot products, a gemm inner loop,
byte search and complex multiply at `apple-a7` and `apple-a13` gives
byte-identical code.  What the baseline costs is elsewhere:

| | `apple-a7` vs `apple-a11`+ |
|---|---|
| atomics (`fetch_add`, `cas`, `swap`, spin lock) | 2–3× the instructions — LL/SC retry loops instead of single-instruction LSE |
| `Float16` arithmetic | 3× (196 vs 65 instructions for a dot product) |
| everything else measured | identical |

The atomics figure is the one that matters, because Julia's runtime is
atomics-dense: GC write barriers, allocation, locks, task switching.  Both
gaps close at A11 and neither a12 nor a13 improves on it; all a13 adds is
SHA3, worth ~9% on Random's generator and nothing elsewhere.  (These are
static instruction counts, not timings.)

**Gate the app to A11 or newer.**  The deployment target does not do this on
its own — `IOS_VERSION_MIN = 16.4` admits A9 iPads, and even iOS 17/18 admit
A10 ones.  Either:

- declare the app **iPhone-only** (Supported Destinations → iPhone), where
  iOS 16 already means A11 or newer; or
- add `iphone-ipad-minimum-performance-a12` to `UIRequiredDeviceCapabilities`,
  which gives A12+ across both families.

If the app has to reach older hardware, `IOS_CPU_TARGET=apple-a7` is the
arm64 iOS baseline and needs no gating at all — at the cost in the table
above.

Multiversioning — `IOS_CPU_TARGET='apple-a7;apple-m1,clone_all'` — is the way
to keep the baseline and a fast path in one binary.  It costs sysimage size
and bake time, and it is **not covered by CI**: it depends on the runtime
identifying the chip correctly, which on iOS comes from the
`hw.optional.arm.FEAT_*` sysctls (`src/processor_arm.cpp`), and the simulator
only ever presents the build machine's CPU.

To confirm what a built artifact actually requires:

```
otool -tvV Frameworks/JuliaSysimage.framework/JuliaSysimage \
  | grep -cowE 'casal|ldaddal|swpal'     # nonzero => needs A11 or newer
otool -tvV Frameworks/JuliaSysimage.framework/JuliaSysimage \
  | grep -cowE 'eor3|xar|bcax|rax1'      # nonzero => needs A13 or newer
```

## Build-host paths in the shipped artifacts (audited by the build)

A build-machine path that does not exist on the device is skipped at
runtime, so it costs nothing behaviourally — but it publishes the
developer's username and directory layout in a binary that goes through
App Store review, and it is a reliable sign that something in the build
is not relocatable.  `build-xcframework.sh` runs
`contrib/ios/check-host-paths.sh` over the finished output and reports
what it finds; run it standalone any time with

```
contrib/ios/check-host-paths.sh <output-dir>
```

Four categories, only the first of which fails the check:

- **A path the runtime would open** — a JLL `LIBPATH`, an artifact or
  depot directory, a dylib.  A hit here is a real defect.  The usual source
  would be a module initializer run during the sysimage build: a JLL's
  `__init__` appends its library directory to lists that are serialized with
  the image.  An ordinary build does not run initializers, and
  `sysimage_env_init.jl`, which does for builds that bake extra packages,
  clears those lists afterwards.
- **Baked source paths.** Julia records the absolute path of every source
  file it bakes (`Method.file`, and `Sys.BUILD_STDLIB_PATH`), rewriting
  them to the runtime location only for *display*
  (`Base.fixup_stdlib_path`).  Those strings are in `JuliaSysimage` by
  construction and no init-time cleanup removes them.  To keep a username
  out of them, build from a directory that has none — e.g. clone and build
  (host julia included) under `/opt/julia-ios` rather than `~/…`.
- **A vendored dependency's own `--prefix`**, compiled into that
  dependency's binary; OpenSSL's `OPENSSLDIR` and `ENGINESDIR` are the
  usual ones.  Those directories cannot exist on a device and are not
  consulted there.
- **Strings merely shaped like paths** — a test fixture, or a docstring
  quoting a `file:///C:/…` URL — reported so they are not mistaken for
  leakage.

Set `IOS_STRICT_PATH_AUDIT=1` to fail on all four once your build tree is
neutral.

## Still verify per submission

- **No stray Mach-O files in `julia-runtime-resources/`**: if your
  `IOS_SYSIMAGE_EXTRA_PROJECT` pulls in binary JLL packages, their artifact
  trees contain (host-macOS!) dylibs that would be loose binaries in the
  bundle — the same rejection class the frameworks split fixed.  Check with
  `find julia-runtime-resources \( -name '*.dylib' -o -name '*.so' \)` and
  audit anything it prints.
- **Framework platform metadata**: every framework binary should carry an
  iOS `LC_BUILD_VERSION` matching its plist's `MinimumOSVersion`:
  `for f in Frameworks/*.framework; do vtool -show-build "$f/$(basename "$f" .framework)" | grep -E 'platform|minos'; done`
- **App size**: libLLVM dominates the download; strip (`strip -x`) and
  App Thinning help, and a codegen-stub build that drops LLVM entirely is
  the long-term fix.
