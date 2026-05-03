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
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleVersion string $(JULIA_COMMIT)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleShortVersionString string $(JULIA_MAJOR_VERSION).$(JULIA_MINOR_VERSION).$(JULIA_PATCH_VERSION)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSignature string ????" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundlePackageType string FMWK" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleInfoDictionaryVersion string 6.0" $@
	/usr/libexec/PlistBuddy -x -c "Add :MinimumOSVersion string $(IOS_VERSION_MIN)" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSupportedPlatforms array" $@
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSupportedPlatforms:0 string $(IOS_PLIST_PLATFORM)" $@
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
# Every .dylib in $(build_shlibdir) is bundled except for test-only libraries
# and the libjulia loader (which is copied separately as the framework binary).
# Versioned variants (e.g. libfoo.1.12.dylib) are skipped — only the
# unversioned name is copied (via -fL to dereference symlinks), and explicit
# versioned symlinks are created for the libraries that need them.
#
# Install-name strategy:
#   - Each library's LC_ID_DYLIB is set to @rpath/Julia.framework/<name>
#     so that apps can link against the framework with the standard
#     @executable_path/Frameworks rpath.
#   - All intra-framework LC_LOAD_DYLIB references are rewritten from
#     @rpath/<name> to @loader_path/<name> so that libraries within the
#     framework find each other regardless of the app's rpath setup.
install-libs: | $(framework_destdirs)
	@# --- Copy the main framework binary (libjulia) ---
	cp -fL $(build_shlibdir)/libjulia.$(JL_MAJOR_MINOR_SHLIB_EXT) $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	@# --- Copy all other shared libraries ---
	@for lib in $(build_shlibdir)/*.$(SHLIB_EXT); do \
		name=$$(basename $$lib); \
		case $$name in \
			libjulia.$(SHLIB_EXT)) continue ;; \
			libccalltest*|libccalllazy*|libllvmcalltest*) continue ;; \
			*.[0-9]*.$(SHLIB_EXT)) continue ;; \
		esac; \
		cp -fL $$lib $(IOS_FWDIR)/$$name; \
	done
	@# --- Copy the system image (may not exist during cross-compilation) ---
	@if [ -f $(build_private_shlibdir)/sys.$(SHLIB_EXT) ]; then \
		cp -fL $(build_private_shlibdir)/sys.$(SHLIB_EXT) $(IOS_FWDIR)/sys.$(SHLIB_EXT); \
	fi
	@# --- Versioned symlinks ---
	@# The framework contains only unversioned dylibs (e.g. libgmp.dylib).
	@# Julia ccall constants and inter-library SONAMEs reference versioned
	@# names (e.g. @rpath/libgmp.10.dylib, @rpath/libpcre2-8.0.dylib).
	@# Create symlinks so that versioned lookups resolve to the unversioned
	@# copies.
	@#
	@# libjulia is special — the framework binary is named "Julia", not
	@# "libjulia.dylib", so handle it manually.
	ln -sf $(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/libjulia.$(JL_MAJOR_SHLIB_EXT)
	ln -sf $(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/libjulia.$(JL_MAJOR_MINOR_SHLIB_EXT)
	@# Scan the build directory for all versioned dylib names and create
	@# symlinks pointing to the corresponding unversioned file in the
	@# framework (e.g. libgmp.10.dylib → libgmp.dylib).
	@for lib in $(build_shlibdir)/*.[0-9]*.$(SHLIB_EXT); do \
		[ -e "$$lib" ] || continue; \
		name=$$(basename "$$lib"); \
		unversioned=$$(echo "$$name" | sed -E 's/\.[0-9]+(\.[0-9]+)*\.dylib$$/.dylib/'); \
		if [ -f "$(IOS_FWDIR)/$$unversioned" ] && [ ! -e "$(IOS_FWDIR)/$$name" ]; then \
			ln -sf "$$unversioned" "$(IOS_FWDIR)/$$name"; \
		fi; \
	done
	@# --- Fix up install names ---
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	@for lib in $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/*.$(SHLIB_EXT); do \
		[ -f $$lib ] || continue; \
		name=$$(basename $$lib); \
		if [ "$$name" != "$(IOS_FRAMEWORK_NAME)" ]; then \
			install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/$$name $$lib 2>/dev/null || true; \
		fi; \
		for dep in $$(otool -L $$lib 2>/dev/null | tail -n +2 | grep '@rpath/' | awk '{print $$1}'); do \
			new=$$(echo $$dep | sed 's|@rpath/|@loader_path/|'); \
			install_name_tool -change $$dep $$new $$lib 2>/dev/null || true; \
		done; \
	done

# Codesign the framework
codesign:
	codesign -s "$(DARWIN_CODESIGN_KEYCHAIN_IDENTITY)" -f \
		$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)

framework: build-julia \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/Info.plist \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_MODULES)/module.modulemap \
	$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h \
	install-headers install-libs codesign
	@echo ""
	@echo "iOS framework built successfully ($(IOS_PLATFORM)):"
	@echo "  $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)"
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
