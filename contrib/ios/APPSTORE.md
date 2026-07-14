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

The framework set bundles real cryptography: mbedTLS (TLS for libcurl /
libgit2) and libssh2 (SSH for LibGit2).  For the App Store Connect
questions:

- **"Is your app designed to use cryptography or does it contain or
  incorporate cryptography?"** — **Yes.** (Bundled mbedTLS/libssh2 count
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
