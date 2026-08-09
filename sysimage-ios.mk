# Cross-target sysimage build for iOS.
#
# Mirrors sysimage.mk but uses the in-tree host julia (at
# $(JULIAHOME)/usr/bin/julia, produced by a standard `make` in the source
# tree without IOS=1) for the bake stages, and the --target=<triple> CLI
# flag (added in src/jloptions.c) so --output-o emits an iOS arm64 object
# instead of a host-darwin one.
#
# Expected workflow:
#   cd $(JULIAHOME) && make                     # host build (one-time)
#   make O=build-ios-device configure           # out-of-tree iOS BUILDROOT
#   make -C build-ios-device IOS=1 julia-release
#
# In-tree iOS builds (BUILDROOT == JULIAHOME with IOS=1) would clobber
# the host's usr/lib/libjulia.dylib + sys.dylib and break the host julia;
# we error out in that case below.
#
# Stages:
#   1. basecompiler.ji  — host julia, platform-neutral IR.
#   2. sysbase.ji       — host julia, platform-neutral IR, --compile=all.
#   3. sys-o.a          — host julia with --output-o + --target=arm64-apple-iosX,
#                          --compile=all.  Object archive of iOS arm64 Mach-O.
#
# Upstream sysimage.mk chains these through native dylibs; here every
# intermediate stays a `.ji`, because a native link in this tree would be an
# iOS one and the host julia has to load the image it just produced.
#   4. sys.$(SHLIB_EXT) — link sys-o.a into sys.dylib using xcrun's iOS clang
#                          and iOS SDK.  Lands in $(build_private_libdir) where
#                          contrib/ios/Makefile install-libs picks it up.

SRCDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILDDIR := .
JULIAHOME := $(SRCDIR)
include $(JULIAHOME)/Make.inc
include $(JULIAHOME)/stdlib/stdlib.mk

# Guard against in-tree iOS builds (would clobber the host julia).
ifeq ($(abspath $(BUILDROOT)),$(abspath $(JULIAHOME)))
$(error iOS sysimage build requires an out-of-tree BUILDROOT — \
        running IOS=1 in-tree would overwrite the host julia at \
        $(JULIAHOME)/usr/.  Run `make O=build-ios-device configure` \
        and `make -C build-ios-device IOS=1 ...` instead, \
        or set NO_SYSIMAGE=1 to skip sysimage generation)
endif

default: sysimg-ios-$(JULIA_BUILD_MODE)
all: sysimg-ios-release sysimg-ios-debug
sysimg-ios-release: $(build_private_libdir)/sys.$(SHLIB_EXT)
sysimg-ios-debug: $(build_private_libdir)/sys-debug.$(SHLIB_EXT)

VERSDIR := v$(shell cut -d. -f1-2 < $(JULIAHOME)/VERSION)

IOS_TRIPLE := arm64-apple-ios$(IOS_VERSION_MIN)
# Simulator slice needs the -simulator suffix on the triple so the LLVM
# AArch64 backend emits a Mach-O with platform marker LC_BUILD_VERSION =
# iOSSimulator (not iOS); otherwise stage 4 link fails with
# `building for 'iOS' but linking in dylib built for 'iOS-simulator'`.
ifeq ($(IOS_PLATFORM),iphonesimulator)
IOS_TRIPLE := $(IOS_TRIPLE)-simulator
endif
# Resolve at recipe time, not parse time (this file is referenced by the
# top-level iOS gate which is itself evaluated even on non-IOS makes).
IOS_LINKER = $(shell xcrun --sdk $(IOS_PLATFORM) -f clang 2>/dev/null)

# Framework name for the sysimage install_name.  IOS_FRAMEWORK_NAME is the
# variable contrib/ios and build-xcframework.sh pass around; FRAMEWORK_NAME
# is Make.inc's macOS framework variable (default "Julia"), kept as the
# fallback so a bare `make -f sysimage-ios.mk` still produces a sane id.
IOS_FRAMEWORK_NAME ?= $(FRAMEWORK_NAME)

# Optional: extra Julia code baked into the iOS sysimage at stage 3.  Set
# IOS_SYSIMAGE_EXTRA_JL=/abs/path/to/extras.jl (or a space-separated list of
# paths) and each file is loaded via the host julia's -L flag before
# generate_precompile.jl runs.  At that point sysbase.ji is loaded as the
# sysimage, so Base + every stdlib are available — your file can `using ...`,
# define modules / methods / consts, and even call them to get those calls
# precompiled into the resulting sys.dylib's native code.
IOS_SYSIMAGE_EXTRA_JL ?=

# Optional: extra Julia project whose packages should be baked into the iOS
# sysimage.  Set IOS_SYSIMAGE_EXTRA_PROJECT=/abs/path/to/project-dir, where
# the directory contains Project.toml + Manifest.toml.  Run
# `julia --pkgimages=no --project=<dir> -e 'using Pkg; Pkg.instantiate()'`
# first so the host's depot has the package sources downloaded.  Combined
# with IOS_SYSIMAGE_EXTRA_JL containing `using SomePackage` lines, the listed
# packages get baked into sys.dylib.
#
# NOTE on --pkgimages=no: precompilation then emits only the .ji serialized
# cache and no native .dylib, which is all the bake needs — stage 3 loads the
# package to compile its methods into sys.dylib via --compile=all, so host-side
# native pkgimages never affect the result.  Skipping them saves a link per
# package.
#
# NOTE: only pure-Julia packages bake cleanly.  Packages that load JLLs
# (Foo_jll) require the corresponding lib<foo>.dylib to be shipped in the
# iOS framework AND iOS-compatible artifact binaries to be available at
# runtime — neither happens automatically.  Test before assuming a given
# package works on iOS.
IOS_SYSIMAGE_EXTRA_PROJECT ?=

# The stdlibs this bake loads, named as a path rather than left to `@stdlib`.
# `@stdlib` resolves through Sys.STDLIB, which Sys.__init_build() derives from
# the running julia's bindir -- the host prefix, since the host julia is what
# runs the bake.  In an out-of-tree build that is the wrong tree twice over:
# its stdlib entries are symlinks into $(JULIAHOME)/stdlib, and stdlib/Makefile
# extracts an external stdlib under $(BUILDROOT)/stdlib instead, so nothing
# ever creates what they point at and `using SHA` fails with "Package SHA not
# found in current path".  This build's own directory is populated by
# julia-stdlib and holds the very sources STDLIB_SRCS lists, which is what the
# bake should be reading.  A directory in LOAD_PATH is a package-directory
# environment, exactly what `@stdlib` expands to.
IOS_STDLIB_PATH := $(build_datarootdir)/julia/stdlib/$(VERSDIR)

# Env vars pointing the host julia at its in-tree bindir / sysimage / depot.
# When IOS_SYSIMAGE_EXTRA_PROJECT is set, activate that project and let the
# host's default depot be visible (so installed packages resolve); otherwise
# lock down to stdlib only, which is what the regular bake expects.
ifneq ($(IOS_SYSIMAGE_EXTRA_PROJECT),)
HOST_JULIA_ENV := JULIA_BINDIR=$(JULIAHOME)/usr/bin \
                 JULIA_LOAD_PATH=@:$(IOS_STDLIB_PATH) \
                 JULIA_PROJECT=$(IOS_SYSIMAGE_EXTRA_PROJECT) \
                 JULIA_NUM_THREADS=1
else
HOST_JULIA_ENV := JULIA_BINDIR=$(JULIAHOME)/usr/bin \
                 JULIA_LOAD_PATH=$(IOS_STDLIB_PATH) \
                 JULIA_PROJECT= \
                 JULIA_DEPOT_PATH=: \
                 JULIA_NUM_THREADS=1
endif

# When extra code/packages are baked in, prepend a preamble that initializes
# the loading environment.  Stage 3 runs in `--output-o` mode, which skips
# Base.__init__, leaving Sys.STDLIB / LOAD_PATH / DEPOT_PATH / active project
# unset — so a `using SomePkg` in an EXTRA_JL file would fail to resolve.  The
# preamble re-runs those init steps (honoring HOST_JULIA_ENV) before the
# warm-up files load.  Empty for a plain bake with no extras.
#
# Also skip generate_precompile.jl's statement collection (pass 0) for
# extra-package bakes.  That collection spawns host subprocesses that load the
# sysimage (JLOptions().image_file) and run it to trace precompile statements —
# but this is a cross-targeted iOS image, and once the extra packages are baked
# in, loading it on the host trips a package init and the subprocess dies (seen
# as EPIPE / a hung fake-PTY REPL).  The statements it would collect are generic
# REPL/interactive signatures of little use to an embedded app anyway; the code
# the app actually needs is compiled by --compile=all as the workload exercises
# it.  Plain (no-extras) iOS bakes keep the normal $(JULIA_PRECOMPILE) value.
ifneq ($(IOS_SYSIMAGE_EXTRA_JL)$(IOS_SYSIMAGE_EXTRA_PROJECT),)
IOS_SYSIMAGE_PRELOAD := -L $(JULIAHOME)/contrib/ios/sysimage_env_init.jl
IOS_PRECOMPILE_ARG := 0
else
IOS_SYSIMAGE_PRELOAD :=
IOS_PRECOMPILE_ARG := $(JULIA_PRECOMPILE)
endif

COMPILER_SRCS := $(addprefix $(JULIAHOME)/, \
		base/Base_compiler.jl \
		base/boot.jl \
		base/docs/core.jl \
		base/abstractarray.jl \
		base/abstractdict.jl \
		base/abstractset.jl \
		base/iddict.jl \
		base/idset.jl \
		base/array.jl \
		base/bitarray.jl \
		base/bitset.jl \
		base/bool.jl \
		base/ctypes.jl \
		base/error.jl \
		base/essentials.jl \
		base/expr.jl \
		base/exports.jl \
		base/generator.jl \
		base/int.jl \
		base/indices.jl \
		base/iterators.jl \
		base/invalidation.jl \
		base/namedtuple.jl \
		base/number.jl \
		base/operators.jl \
		base/options.jl \
		base/pair.jl \
		base/pointer.jl \
		base/promotion.jl \
		base/range.jl \
		base/runtime_internals.jl \
		base/traits.jl \
		base/refvalue.jl \
		base/tuple.jl)
COMPILER_SRCS += $(shell find $(JULIAHOME)/Compiler/src -name \*.jl -and -not -name verifytrim.jl -and -not -name show.jl)
# sort these to remove duplicates
BASE_SRCS := $(sort $(shell find $(JULIAHOME)/base -name \*.jl -and -not -name sysimg.jl) \
                    $(shell find $(BUILDROOT)/base -name \*.jl  -and -not -name sysimg.jl)) \
             $(JULIAHOME)/Compiler/src/ssair/show.jl \
             $(JULIAHOME)/Compiler/src/verifytrim.jl
STDLIB_SRCS := $(JULIAHOME)/base/sysimg.jl $(SYSIMG_STDLIBS_SRCS)
RELBUILDROOT := $(call rel_path,$(JULIAHOME)/base,$(BUILDROOT)/base)/ # <-- make sure this always has a trailing slash
RELDATADIR := $(call rel_path,$(JULIAHOME)/base,$(build_datarootdir))/ # <-- make sure this always has a trailing slash

# Recipe-time check that the in-tree host julia exists.  Run as the
# first step of every stage that invokes $(HOST_JULIA).
define check_host_julia
@if [ ! -x "$(HOST_JULIA)" ]; then \
    echo "ERROR: host julia not found at $(HOST_JULIA)." >&2; \
    echo "       Run \`make\` from $(JULIAHOME) (without IOS=1) first" >&2; \
    echo "       to produce the host julia used to bake the iOS sysimage." >&2; \
    exit 1; \
fi
endef

# Stage 1: basecompiler.ji — platform-neutral IR for the core compiler.
$(build_private_libdir)/basecompiler.ji: $(COMPILER_SRCS)
	$(call check_host_julia)
	@$(call PRINT_JULIA, cd $(JULIAHOME)/base && \
	$(HOST_JULIA_ENV) $(HOST_JULIA) -C $(JULIA_CPU_TARGET) $(HEAPLIM) \
		--output-ji $@.tmp \
		--startup-file=no --warn-overwrite=yes -g$(BOOTSTRAP_DEBUG_LEVEL) -O0 \
		Base_compiler.jl --buildroot $(RELBUILDROOT) --dataroot $(RELDATADIR))
	@mv $@.tmp $@

# Stage 2: sysbase.ji — full sysimage IR, with --compile=all forcing eager
# method lowering so stage 3's --output-o has every method to emit.
$(build_private_libdir)/sysbase.ji: $(build_private_libdir)/basecompiler.ji $(JULIAHOME)/VERSION $(BASE_SRCS) $(STDLIB_SRCS)
	$(call check_host_julia)
	@$(call PRINT_JULIA, cd $(JULIAHOME)/base && \
	if ! $(HOST_JULIA_ENV) $(HOST_JULIA) -g1 -O0 -C $(JULIA_CPU_TARGET) $(HEAPLIM) \
			--compile=all \
			--output-ji $@.tmp $(JULIA_SYSIMG_BUILD_FLAGS) \
			--startup-file=no --warn-overwrite=yes \
			--sysimage $< sysimg.jl --buildroot $(RELBUILDROOT) --dataroot $(RELDATADIR); then \
		echo '*** iOS sysimage stage 2 (sysbase.ji) failed.  Try `make cleanall`. ***'; \
		false; \
	fi )
	@mv $@.tmp $@

# Stage 3: sys$1-o.a — iOS arm64 object archive, cross-emitted via --target.
# --pkgimages=no: when IOS_SYSIMAGE_EXTRA_JL does `using SomePkg`, the host
# loads that package without linking a native pkgimage .dylib for it.  Nothing
# here consumes one — the package's methods are compiled into sys.dylib via
# --compile=all — so the link is pure overhead.
define sysimg_ios_builder
$$(build_private_libdir)/sys$1-o.a : $$(build_private_libdir)/sysbase.ji $$(JULIAHOME)/contrib/generate_precompile.jl $$(JULIAHOME)/contrib/ios/sysimage_env_init.jl
	$$(call check_host_julia)
	@$$(call PRINT_JULIA, cd $$(JULIAHOME)/base && \
	if ! $(HOST_JULIA_ENV) $(HOST_JULIA) $2 -C $(JULIA_CPU_TARGET) $$(HEAPLIM) \
			--compile=all \
			--pkgimages=no \
			--target=$(IOS_TRIPLE) \
			--output-o $$@.tmp $$(JULIA_SYSIMG_BUILD_FLAGS) \
			--startup-file=no --warn-overwrite=yes \
			--sysimage $$< \
			$(IOS_SYSIMAGE_PRELOAD) \
			$(foreach extra,$(IOS_SYSIMAGE_EXTRA_JL),-L $(extra)) \
			$$(JULIAHOME)/contrib/generate_precompile.jl $(IOS_PRECOMPILE_ARG); then \
		echo '*** iOS sysimage stage 3 (sys$1-o.a) failed.  Try `make cleanall`. ***'; \
		false; \
	fi )
	@mv $$@.tmp $$@
.SECONDARY: $$(build_private_libdir)/sys$1-o.a
endef
$(eval $(call sysimg_ios_builder,,-O3))
$(eval $(call sysimg_ios_builder,-debug,-O0))

# Stage 4: sys.$(SHLIB_EXT) — link the iOS arm64 object into the iOS dylib
# using xcrun clang with the iOS SDK + version-min.  This overrides the
# generic rule in sysimage.mk (which uses $(CXX)) because we need iOS SDK
# context, not the macOS-host CXX.
$(build_private_libdir)/%.$(SHLIB_EXT): $(build_private_libdir)/%-o.a
	@if [ -z "$(IOS_LINKER)" ]; then \
		echo "ERROR: xcrun could not locate clang for SDK '$(IOS_PLATFORM)'.  Install Xcode + iOS SDK." >&2; \
		exit 1; \
	fi
	@# NOTE: embedded commas in -Wl,-install_name,... would be parsed by
	@# $(call ...) as additional macro arguments, dropping everything past
	@# the first comma in the payload (PRINT_LINK only emits $1).  Set the
	@# install_name as a separate post-link step instead, mirroring the
	@# pattern used by the regular sysimage.mk's link rule.
	@$(call PRINT_LINK, $(IOS_LINKER) -dynamiclib \
		-arch arm64 $(IOS_VERSION_MIN_FLAG) -isysroot $(IOS_SDK) \
		-L$(build_private_libdir) -L$(build_libdir) -L$(build_shlibdir) \
		$(WHOLE_ARCHIVE) $< $(NO_WHOLE_ARCHIVE) \
		$(if $(findstring -debug,$(notdir $@)),-ljulia-internal-debug -ljulia-debug,-ljulia-internal -ljulia) \
		-o $@)
	@install_name_tool -id @rpath/$(IOS_FRAMEWORK_NAME).framework/$(notdir $@) $@
