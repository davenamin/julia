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
#   1. corecompiler.ji  — host julia, platform-neutral IR.
#   2. sys.ji           — host julia, platform-neutral IR, --compile=all.
#   3. sys-o.a          — host julia with --output-o + --target=arm64-apple-iosX,
#                          --compile=all.  Object archive of iOS arm64 Mach-O.
#   4. sys.$(SHLIB_EXT) — link sys-o.a into sys.dylib using xcrun's iOS clang
#                          and iOS SDK.  Lands in $(build_private_libdir) where
#                          contrib/ios/Makefile install-libs picks it up.

SRCDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILDDIR := .
JULIAHOME := $(SRCDIR)
include $(JULIAHOME)/Make.inc

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
# Resolve at recipe time, not parse time (this file is referenced by the
# top-level iOS gate which is itself evaluated even on non-IOS makes).
IOS_LINKER = $(shell xcrun --sdk $(IOS_PLATFORM) -f clang 2>/dev/null)

# Env vars pointing the host julia at its in-tree bindir / sysimage / depot.
HOST_JULIA_ENV := JULIA_BINDIR=$(JULIAHOME)/usr/bin \
                 JULIA_LOAD_PATH=@stdlib \
                 JULIA_PROJECT= \
                 JULIA_DEPOT_PATH=: \
                 JULIA_NUM_THREADS=1

COMPILER_SRCS := $(addprefix $(JULIAHOME)/, \
		base/boot.jl base/docs/core.jl base/abstractarray.jl base/abstractdict.jl \
		base/array.jl base/bitarray.jl base/bitset.jl base/bool.jl base/ctypes.jl \
		base/error.jl base/essentials.jl base/expr.jl base/generator.jl base/int.jl \
		base/indices.jl base/iterators.jl base/namedtuple.jl base/number.jl \
		base/operators.jl base/options.jl base/pair.jl base/pointer.jl \
		base/promotion.jl base/range.jl base/reflection.jl base/traits.jl \
		base/refvalue.jl base/tuple.jl)
COMPILER_SRCS += $(shell find $(JULIAHOME)/base/compiler -name \*.jl)
BASE_SRCS := $(sort $(shell find $(JULIAHOME)/base -name \*.jl -and -not -name sysimg.jl) \
                    $(shell find $(BUILDROOT)/base -name \*.jl -and -not -name sysimg.jl))
STDLIB_SRCS := $(JULIAHOME)/base/sysimg.jl \
               $(shell find $(JULIAHOME)/usr/share/julia/stdlib/$(VERSDIR)/*/src -name \*.jl 2>/dev/null) \
               $(wildcard $(JULIAHOME)/usr/manifest/$(VERSDIR)/*)
RELBUILDROOT := $(call rel_path,$(JULIAHOME)/base,$(BUILDROOT)/base)/

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

# Stage 1: corecompiler.ji — platform-neutral IR for the core compiler.
$(build_private_libdir)/corecompiler.ji: $(COMPILER_SRCS)
	$(call check_host_julia)
	@$(call PRINT_JULIA, cd $(JULIAHOME)/base && \
	$(HOST_JULIA_ENV) $(HOST_JULIA) -C apple-m1 $(HEAPLIM) \
		--output-ji $@.tmp \
		--startup-file=no --warn-overwrite=yes -g$(BOOTSTRAP_DEBUG_LEVEL) -O0 \
		compiler/compiler.jl)
	@mv $@.tmp $@

# Stage 2: sys.ji — full sysimage IR, with --compile=all forcing eager method
# lowering so stage 3's --output-o has every method to emit.
$(build_private_libdir)/sys.ji: $(build_private_libdir)/corecompiler.ji $(JULIAHOME)/VERSION $(BASE_SRCS) $(STDLIB_SRCS)
	@$(call PRINT_JULIA, cd $(JULIAHOME)/base && \
	if ! $(HOST_JULIA_ENV) $(HOST_JULIA) -g1 -O0 -C apple-m1 $(HEAPLIM) \
			--compile=all \
			--output-ji $@.tmp $(JULIA_SYSIMG_BUILD_FLAGS) \
			--startup-file=no --warn-overwrite=yes \
			--sysimage $< sysimg.jl $(RELBUILDROOT); then \
		echo '*** iOS sysimage stage 2 (sys.ji) failed.  Try `make cleanall`. ***'; \
		false; \
	fi )
	@mv $@.tmp $@

# Stage 3: sys$1-o.a — iOS arm64 object archive, cross-emitted via --target.
define sysimg_ios_builder
$$(build_private_libdir)/sys$1-o.a : $$(build_private_libdir)/sys.ji $$(JULIAHOME)/contrib/generate_precompile.jl
	@$$(call PRINT_JULIA, cd $$(JULIAHOME)/base && \
	if ! $(HOST_JULIA_ENV) $(HOST_JULIA) $2 -C apple-m1 $$(HEAPLIM) \
			--compile=all \
			--target=$(IOS_TRIPLE) \
			--output-o $$@.tmp $$(JULIA_SYSIMG_BUILD_FLAGS) \
			--startup-file=no --warn-overwrite=yes \
			--sysimage $$< $$(JULIAHOME)/contrib/generate_precompile.jl $(JULIA_PRECOMPILE); then \
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
	@$(call PRINT_LINK, $(IOS_LINKER) -dynamiclib \
		-arch arm64 -mios-version-min=$(IOS_VERSION_MIN) -isysroot $(IOS_SDK) \
		-Wl,-install_name,@rpath/$(FRAMEWORK_NAME).framework/$(notdir $@) \
		-L$(build_private_libdir) -L$(build_libdir) -L$(build_shlibdir) \
		-Wl,-force_load,$< \
		$(if $(findstring -debug,$(notdir $@)),-ljulia-internal-debug -ljulia-debug,-ljulia-internal -ljulia) \
		-o $@)
