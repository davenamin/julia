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

# Generate the module map — use an umbrella directory so that Clang picks up
# all headers under Headers/julia/ (including the uv/ subdirectory) as part
# of the module.
$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_MODULES)/module.modulemap: | $(framework_destdirs)
	@echo 'framework module $(IOS_FRAMEWORK_NAME) [extern_c] [system] {' > $@
	@echo '  umbrella "julia"' >> $@
	@echo '  export *' >> $@
	@echo '  module * { export * }' >> $@
	@echo '}' >> $@

# Generate the umbrella header
$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h: | $(framework_destdirs)
	@echo '// This file is a part of Julia. License is MIT: https://julialang.org/license' > $@
	@echo '' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/julia.h>' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/julia_threads.h>' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/julia_version.h>' >> $@
	@echo '#include <$(IOS_FRAMEWORK_NAME)/julia/uv.h>' >> $@

# Copy public headers (including uv/ subdirectory that uv.h #includes)
install-headers: | $(framework_destdirs)
	cp $(build_includedir)/julia/*.h $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/julia/
	cp $(build_includedir)/julia/uv/*.h $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/julia/uv/

# Shorthand for the framework output directory
IOS_FWDIR = $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)

# Copy all shared libraries into the framework and fix up install names so that
# the framework is fully self-contained.
#
# Library layout inside the framework:
#   Julia.framework/
#     Julia                         <- main framework binary (libjulia)
#     libjulia.$(JL_MAJOR_SHLIB_EXT) -> Julia   (versioned symlink)
#     libjulia-internal.dylib
#     libjulia-codegen.dylib
#     libLLVM.dylib
#     libunwind.dylib
#     libz.dylib
#
# Install-name strategy:
#   - Each library's LC_ID_DYLIB is set to @rpath/Julia.framework/<name>
#     so that apps can link against the framework with the standard
#     @executable_path/Frameworks rpath.
#   - All intra-framework LC_LOAD_DYLIB references are rewritten from
#     @rpath/<name> to @loader_path/<name> so that libraries within the
#     framework find each other regardless of the app's rpath setup.
install-libs: | $(framework_destdirs)
	@# --- Copy libraries (use -L to follow symlinks) ---
	cp -fL $(build_shlibdir)/libjulia.$(JL_MAJOR_MINOR_SHLIB_EXT) $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	cp -fL $(build_shlibdir)/libjulia-internal.$(JL_MAJOR_MINOR_SHLIB_EXT) $(IOS_FWDIR)/libjulia-internal.dylib
	cp -fL $(build_shlibdir)/libjulia-codegen.$(JL_MAJOR_MINOR_SHLIB_EXT) $(IOS_FWDIR)/libjulia-codegen.dylib
	cp -fL $(build_shlibdir)/libLLVM.dylib $(IOS_FWDIR)/libLLVM.dylib
	cp -fL $(build_shlibdir)/libunwind.dylib $(IOS_FWDIR)/libunwind.dylib
	cp -fL $(build_shlibdir)/libz.dylib $(IOS_FWDIR)/libz.dylib
	@# Versioned symlink: libjulia-internal and codegen reference the
	@# versioned libjulia install name (@loader_path/libjulia.X.Y.dylib)
	ln -sf $(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/libjulia.$(JL_MAJOR_SHLIB_EXT)
	@# --- Rewrite @rpath/ references to @loader_path/ for intra-framework resolution ---
	@for lib in $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/libjulia-internal.dylib \
		    $(IOS_FWDIR)/libjulia-codegen.dylib $(IOS_FWDIR)/libLLVM.dylib \
		    $(IOS_FWDIR)/libunwind.dylib $(IOS_FWDIR)/libz.dylib; do \
		for dep in $$(otool -L $$lib 2>/dev/null | tail -n +2 | grep '@rpath/' | awk '{print $$1}'); do \
			new=$$(echo $$dep | sed 's|@rpath/|@loader_path/|'); \
			install_name_tool -change $$dep $$new $$lib 2>/dev/null || true; \
		done; \
	done
	@# --- Set install name IDs (for linking from the app) ---
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/$(IOS_FRAMEWORK_NAME) $(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/libjulia-internal.dylib $(IOS_FWDIR)/libjulia-internal.dylib
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/libjulia-codegen.dylib $(IOS_FWDIR)/libjulia-codegen.dylib
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/libLLVM.dylib $(IOS_FWDIR)/libLLVM.dylib
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/libunwind.dylib $(IOS_FWDIR)/libunwind.dylib
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/libz.dylib $(IOS_FWDIR)/libz.dylib

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
