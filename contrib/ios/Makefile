JULIAHOME := $(abspath ../..)
include $(JULIAHOME)/Make.inc
include $(JULIAHOME)/deps/llvm-ver.make

# Build Julia as an iOS framework (shared library) or XCFramework.
#
# Single-platform framework (device or simulator):
#   make -C contrib/ios IOS=1 framework
#   make -C contrib/ios IOS=1 IOS_PLATFORM=iphonesimulator framework
#
# XCFramework (combines device + simulator):
#   Requires two separate builds — one per platform — because the compiled
#   binaries differ.  Use out-of-tree builds to keep them apart:
#
#     make O=build-ios-device configure
#     make -C build-ios-device IOS=1 IOS_PLATFORM=iphoneos ios-framework
#
#     make O=build-ios-sim configure
#     make -C build-ios-sim IOS=1 IOS_PLATFORM=iphonesimulator ios-framework
#
#     make -C contrib/ios IOS=1 xcframework \
#       IOS_DEVICE_FRAMEWORK=build-ios-device/usr/share/julia/Julia.framework \
#       IOS_SIM_FRAMEWORK=build-ios-sim/usr/share/julia/Julia.framework

default: framework

# Validate that IOS mode is enabled
ifneq ($(IOS), 1)
$(error iOS framework build requires IOS=1. Run: make -C contrib/ios IOS=1 framework)
endif

# The codesigning identity on Darwin.
DARWIN_CODESIGN_KEYCHAIN_IDENTITY ?= -

# iOS framework structure
IOS_FRAMEWORK_NAME ?= Julia
IOS_FRAMEWORK_BUNDLE_ID ?= org.julialang.julia
IOS_FRAMEWORK_DIR := $(IOS_FRAMEWORK_NAME).framework
IOS_FRAMEWORK_HEADERS := $(IOS_FRAMEWORK_DIR)/Headers
IOS_FRAMEWORK_MODULES := $(IOS_FRAMEWORK_DIR)/Modules

# XCFramework output
IOS_XCFRAMEWORK_DIR := $(IOS_FRAMEWORK_NAME).xcframework

# Platform name for Info.plist — iPhoneOS or iPhoneSimulator
ifeq ($(IOS_PLATFORM),iphonesimulator)
IOS_PLIST_PLATFORM := iPhoneSimulator
else
IOS_PLIST_PLATFORM := iPhoneOS
endif

framework_destdirs := $(addprefix $(DESTDIR)$(prefix)/,$(IOS_FRAMEWORK_DIR) $(IOS_FRAMEWORK_HEADERS) $(IOS_FRAMEWORK_HEADERS)/julia $(IOS_FRAMEWORK_HEADERS)/julia/uv $(IOS_FRAMEWORK_MODULES))

$(framework_destdirs):
	mkdir -p $@

# Build the Julia shared libraries (skip sysimg — it requires running the Julia
# executable, which is impossible during cross-compilation).
build-julia:
	$(MAKE) -C $(JULIAHOME) IOS=1 IOS_PLATFORM=$(IOS_PLATFORM) julia-src-release

# Generate Info.plist for the iOS framework
$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/Info.plist: | $(framework_destdirs)
	/usr/libexec/PlistBuddy -x -c "Clear dict" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleName string $(IOS_FRAMEWORK_NAME)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleExecutable string $(IOS_FRAMEWORK_NAME)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleIdentifier string $(IOS_FRAMEWORK_BUNDLE_ID)" $@
	@# CFBundleVersion must be a period-separated list of at most three
	@# non-negative integers — a git SHA here fails App Store validation.
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleVersion string $(JULIA_MAJOR_VERSION).$(JULIA_MINOR_VERSION).$(JULIA_PATCH_VERSION)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleShortVersionString string $(JULIA_MAJOR_VERSION).$(JULIA_MINOR_VERSION).$(JULIA_PATCH_VERSION)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSignature string ????" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundlePackageType string FMWK" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleInfoDictionaryVersion string 6.0" $@
	/usr/libexec/PlistBuddy -x -c "Add :MinimumOSVersion string $(IOS_VERSION_MIN)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSupportedPlatforms array" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSupportedPlatforms:0 string $(IOS_PLIST_PLATFORM)" $@
	/usr/libexec/PlistBuddy -x -c "Add :DTPlatformName string $(IOS_PLATFORM)" $@
	/usr/libexec/PlistBuddy -x -c "Add :DTSDKName string $(IOS_PLATFORM)$(shell xcrun --sdk $(IOS_PLATFORM) --show-sdk-version 2>/dev/null)" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily array" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily:0 integer 1" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily:1 integer 2" $@

# Generate the module map — use an umbrella header instead of an umbrella
# directory so that the module works reliably inside XCFrameworks (umbrella
# directories can fail to resolve after xcodebuild -create-xcframework
# repackages the framework).
$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_MODULES)/module.modulemap: | $(framework_destdirs)
	@echo 'framework module $(IOS_FRAMEWORK_NAME) [extern_c] [system] {' > $@
	@echo '  umbrella header "$(IOS_FRAMEWORK_NAME).h"' >> $@
	@echo '  export *' >> $@
	@echo '}' >> $@

# Generate the umbrella header
$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h: | $(framework_destdirs)
	@echo '// This file is a part of Julia. License is MIT: https://julialang.org/license' > $@
	@echo '' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/julia.h>' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/julia_threads.h>' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/julia_version.h>' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/uv.h>' >> $@

# Copy public headers (including uv/ subdirectory that uv.h #includes).
# Headers inside uv/ (e.g. unix.h) include siblings with a "uv/" prefix
# (e.g. #include "uv/threadpool.h") which won't resolve when the file is
# already inside the uv/ directory.  Strip the prefix so they find siblings
# directly, while uv.h at the parent level keeps its "uv/" includes intact.
install-headers: | $(framework_destdirs)
	cp $(build_includedir)/julia/*.h $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/julia/
	cp $(build_includedir)/julia/uv/*.h $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/julia/uv/
	sed -i '' -E 's|#[[:space:]]*include "uv/|#include "|g' $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/julia/uv/*.h

# Shorthand for the framework output directory
IOS_FWDIR = $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)

# Copy all shared libraries into the framework and fix up install names so that
# the framework is fully self-contained.
#
# iOS app bundles must not contain symlinks — App Store validation rejects
# them — so unlike a Unix libdir (unversioned symlink → versioned file) the
# framework ships real files only.  Each library needs to resolve under up
# to TWO names, which do not follow a single rule across deps:
#   - its install-name leaf (what other bundled libs' LC_LOAD_DYLIB
#     references use; Julia's source-built deps stamp unversioned ids
#     like @rpath/libgmp.dylib), and
#   - the upstream SONAME the JLL dlopen constants baked into the
#     sysimage use (versioned for most deps, e.g. @rpath/libgmp.10.dylib,
#     but unversioned for e.g. libLLVM).
# So: first each real file is bundled once under its install-name leaf,
# then every remaining alias name present in $(build_shlibdir) is
# materialized as an additional real copy (the symlink fan-out a Unix
# libdir would use, with copies instead of links).  libLLVM is exempted
# from the alias pass — nothing references its versioned alias and the
# copy would double the largest library shipped.
#
# The julia libraries themselves get special names:
#   - libjulia is bundled as the framework binary "$(IOS_FRAMEWORK_NAME)",
#     and every LC_LOAD_DYLIB reference to a libjulia.*.dylib name is
#     rewritten to @loader_path/$(IOS_FRAMEWORK_NAME).
#   - libjulia-internal / libjulia-codegen must be named
#     <base>.$(JL_MAJOR_SHLIB_EXT) — the loader (the framework binary)
#     dlopens them via a DEP_LIBS list baked in at compile time
#     (cli/Makefile), which cannot be rewritten with install_name_tool.
#     Their LC_ID_DYLIB leaf is the *unversioned* name (src/Makefile), so
#     the generic id-leaf rule would miss the loader's versioned lookup.
#
# Install-name strategy:
#   - Each library's LC_ID_DYLIB is set to @rpath/Julia.framework/<name>
#     so that apps can link against the framework with the standard
#     @executable_path/Frameworks rpath.
#   - All intra-framework LC_LOAD_DYLIB references are rewritten from
#     @rpath/<...>/<name> to @loader_path/<name> so that libraries within
#     the framework find each other regardless of the app's rpath setup.
install-libs: | $(framework_destdirs)
	@# --- Start from a clean slate ---
	@# Remove every binary from a previous run first.  Leftover files under
	@# names the current layout no longer produces (e.g. after a naming
	@# scheme change) can otherwise get loaded as a SECOND copy of a
	@# library at runtime — Julia detects that at init with the cryptic
	@# "System image file failed consistency check" error.
	rm -f $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/*.$(SHLIB_EXT)
	@# --- Copy the main framework binary (libjulia) ---
	cp -fL $(build_shlibdir)/libjulia.$(JL_MAJOR_MINOR_SHLIB_EXT) $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	@# --- Copy all other shared libraries under their canonical names ---
	@for lib in $(build_shlibdir)/*.$(SHLIB_EXT); do \
		[ -f "$$lib" ] && [ ! -L "$$lib" ] || continue; \
		name=$$(basename "$$lib"); \
		case $$name in \
			libjulia.$(SHLIB_EXT)|libjulia.[0-9]*.$(SHLIB_EXT)) continue ;; \
			libccalltest*|libccalllazy*|libllvmcalltest*) continue ;; \
		esac; \
		case $$name in \
			libjulia-internal*|libjulia-codegen*) \
				canonical="$${name%%.*}.$(JL_MAJOR_SHLIB_EXT)" ;; \
			*) \
				id=$$(otool -D "$$lib" 2>/dev/null | sed -n '2p'); \
				if [ -n "$$id" ]; then canonical=$$(basename "$$id"); else canonical=$$name; fi ;; \
		esac; \
		cp -f "$$lib" "$(IOS_FWDIR)/$$canonical"; \
	done
	@# --- Materialize every alias name as a real copy ---
	@# The JLL dlopen constants baked into the sysimage reference each
	@# library by its upstream SONAME (e.g. @rpath/libgmp.10.dylib), which
	@# for source-built deps is often a DIFFERENT name than the library's
	@# install-name leaf (Julia's deps stamp unversioned ids like
	@# @rpath/libgmp.dylib).  Both names exist in $(build_shlibdir) — one
	@# as the real file, one as a symlink — and both must resolve at
	@# runtime.  Symlinks are forbidden in iOS bundles, so ship a real
	@# copy under every name found in the build libdir.  libLLVM is
	@# exempt: nothing references its versioned alias (libLLVM-*jl) at
	@# runtime and the copy would double the largest library shipped.
	@for lib in $(build_shlibdir)/*.$(SHLIB_EXT); do \
		name=$$(basename "$$lib"); \
		case $$name in \
			libjulia.$(SHLIB_EXT)|libjulia.[0-9]*.$(SHLIB_EXT)) continue ;; \
			libjulia-internal*|libjulia-codegen*|libLLVM*) continue ;; \
			libccalltest*|libccalllazy*|libllvmcalltest*) continue ;; \
		esac; \
		[ -e "$(IOS_FWDIR)/$$name" ] && continue; \
		cp -fL "$$lib" "$(IOS_FWDIR)/$$name"; \
	done
	@# --- Copy the system image (may not exist during cross-compilation) ---
	@if [ -f $(build_private_shlibdir)/sys.$(SHLIB_EXT) ]; then \
		cp -fL $(build_private_shlibdir)/sys.$(SHLIB_EXT) $(IOS_FWDIR)/sys.$(SHLIB_EXT); \
	fi
	@# --- Fix up install names ---
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	@for lib in $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/*.$(SHLIB_EXT); do \
		[ -f $$lib ] || continue; \
		name=$$(basename $$lib); \
		if [ "$$name" != "$(IOS_FRAMEWORK_NAME)" ]; then \
			install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/$$name $$lib 2>/dev/null || true; \
		fi; \
		for dep in $$(otool -L $$lib 2>/dev/null | tail -n +2 | grep '@rpath/' | awk '{print $$1}'); do \
			leaf=$$(basename $$dep); \
			case $$leaf in \
				libjulia.$(SHLIB_EXT)|libjulia.[0-9]*.$(SHLIB_EXT)) \
					new="@loader_path/$(IOS_FRAMEWORK_NAME)" ;; \
				libjulia-internal*|libjulia-codegen*) \
					new="@loader_path/$${leaf%%.*}.$(JL_MAJOR_SHLIB_EXT)" ;; \
				*) \
					new="@loader_path/$$leaf" ;; \
			esac; \
			install_name_tool -change $$dep $$new $$lib 2>/dev/null || true; \
		done; \
	done

# Codesign the framework.
#
# Apple's AMFI (Apple Mobile File Integrity) checks every Mach-O image on
# dlopen() and refuses to map any binary without its own valid embedded
# LC_CODE_SIGNATURE.  Signing the framework root alone signs only the
# framework binary and writes a CodeResources manifest — the bundled
# dylibs inside (libLLVM, libopenblas, libgmp, sys.dylib, ...) carry no
# signature of their own and would fail dlopen at runtime on iOS.
#
# Sign bottom-up: each leaf dylib first, then the framework binary, then
# the framework root (so its CodeResources reflects the signed contents).
codesign:
	@# 1. Sign every bundled dylib individually.  Skip symlinks so we
	@#    don't re-sign the same underlying file under multiple names.
	@for lib in $(IOS_FWDIR)/*.$(SHLIB_EXT); do \
		[ -f "$$lib" ] && [ ! -L "$$lib" ] || continue; \
		codesign -s "$(DARWIN_CODESIGN_KEYCHAIN_IDENTITY)" -f \
			--timestamp=none "$$lib" || exit 1; \
	done
	@# 2. Sign the sysimage explicitly (its name doesn't always match the
	@#    *.$(SHLIB_EXT) glob if the build laid it out differently).
	@if [ -f $(IOS_FWDIR)/sys.$(SHLIB_EXT) ] && [ ! -L $(IOS_FWDIR)/sys.$(SHLIB_EXT) ]; then \
		codesign -s "$(DARWIN_CODESIGN_KEYCHAIN_IDENTITY)" -f \
			--timestamp=none $(IOS_FWDIR)/sys.$(SHLIB_EXT) || exit 1; \
	fi
	@# 3. Sign the framework's main binary.
	codesign -s "$(DARWIN_CODESIGN_KEYCHAIN_IDENTITY)" -f \
		--timestamp=none $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	@# 4. Sign the framework root last so CodeResources records hashes
	@#    of the now-signed contents.
	codesign -s "$(DARWIN_CODESIGN_KEYCHAIN_IDENTITY)" -f \
		--timestamp=none $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)

# Explicit inter-step dependencies so the framework target is safe under
# `make -j` (prerequisites of a single target carry no ordering guarantee):
# libraries must exist before codesign runs, and the built tree must exist
# before anything is copied out of it.
install-headers install-libs: build-julia
codesign: install-libs install-headers \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/Info.plist \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_MODULES)/module.modulemap \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h

framework: build-julia \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/Info.plist \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_MODULES)/module.modulemap \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h \
	install-headers install-libs codesign
	@echo ""
	@echo "iOS framework built successfully ($(IOS_PLATFORM)):"
	@echo "  $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)"
	@echo ""
	@echo "To embed in an Xcode app:"
	@echo "  1. Drag $(IOS_FRAMEWORK_NAME).framework into the target's 'Frameworks,"
	@echo "     Libraries, and Embedded Content' list with 'Embed & Sign' selected."
	@echo "  2. For device / App Store builds (ad-hoc signing only works on the"
	@echo "     simulator), choose one of:"
	@echo "       (A) Re-build this framework passing your Apple identity, e.g."
	@echo "             make IOS=1 ios-framework \\"
	@echo "               DARWIN_CODESIGN_KEYCHAIN_IDENTITY=\"Apple Development: ...\""
	@echo "           Then Xcode's Embed phase signs the framework root with the same"
	@echo "           identity and the internal dylibs already match."
	@echo "       (B) Add a 'Run Script' build phase after 'Embed Frameworks' that"
	@echo "           invokes contrib/ios/resign-internal-dylibs.sh.  The script"
	@echo "           walks the embedded framework, re-signs each internal dylib"
	@echo "           with the app's identity (\$$EXPANDED_CODE_SIGN_IDENTITY), and"
	@echo "           re-signs the framework root so CodeResources reflects them."
	@echo ""

# XCFramework — combines pre-built device and simulator frameworks.
#
# Set IOS_DEVICE_FRAMEWORK and IOS_SIM_FRAMEWORK to the paths of the
# respective Julia.framework directories.  See the top-of-file comment for the
# recommended workflow using out-of-tree builds.
IOS_DEVICE_FRAMEWORK ?=
IOS_SIM_FRAMEWORK ?=

xcframework:
	@test -n "$(IOS_DEVICE_FRAMEWORK)" || \
		{ echo "Error: IOS_DEVICE_FRAMEWORK not set." \
		       "Set it to the path of the iphoneos Julia.framework."; exit 1; }
	@test -n "$(IOS_SIM_FRAMEWORK)" || \
		{ echo "Error: IOS_SIM_FRAMEWORK not set." \
		       "Set it to the path of the iphonesimulator Julia.framework."; exit 1; }
	@test -d "$(IOS_DEVICE_FRAMEWORK)" || \
		{ echo "Error: device framework not found at $(IOS_DEVICE_FRAMEWORK)"; exit 1; }
	@test -d "$(IOS_SIM_FRAMEWORK)" || \
		{ echo "Error: simulator framework not found at $(IOS_SIM_FRAMEWORK)"; exit 1; }
	rm -rf $(DESTDIR)$(prefix)/$(IOS_XCFRAMEWORK_DIR)
	xcodebuild -create-xcframework \
		-framework $(IOS_DEVICE_FRAMEWORK) \
		-framework $(IOS_SIM_FRAMEWORK) \
		-output $(DESTDIR)$(prefix)/$(IOS_XCFRAMEWORK_DIR)
	@echo ""
	@echo "XCFramework built successfully:"
	@echo "  $(DESTDIR)$(prefix)/$(IOS_XCFRAMEWORK_DIR)"
	@echo ""

clean:
	rm -rf $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)
	rm -rf $(DESTDIR)$(prefix)/$(IOS_XCFRAMEWORK_DIR)

.PHONY: default framework build-julia install-headers install-libs codesign xcframework clean
