JULIAHOME := $(abspath ../..)
include $(JULIAHOME)/Make.inc

# Build Julia as an iOS framework (shared library)
# Usage: make -C contrib/ios IOS=1 framework

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

framework_destdirs := $(addprefix $(DESTDIR)$(prefix)/,$(IOS_FRAMEWORK_DIR) $(IOS_FRAMEWORK_HEADERS) $(IOS_FRAMEWORK_HEADERS)/julia $(IOS_FRAMEWORK_MODULES))

$(framework_destdirs):
	mkdir -p $@

# Build the Julia shared libraries first
build-julia:
	$(MAKE) -C $(JULIAHOME) IOS=1

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
	/usr/libexec/PlistBuddy -x -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily array" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily:0 integer 1" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily:1 integer 2" $@

# Generate the module map
$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_MODULES)/module.modulemap: | $(framework_destdirs)
	@echo 'framework module $(IOS_FRAMEWORK_NAME) [extern_c] [system] {' > $@
	@echo '  umbrella header "$(IOS_FRAMEWORK_NAME).h"' >> $@
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

# Copy public headers
install-headers: | $(framework_destdirs)
	cp $(build_includedir)/julia/*.h $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_HEADERS)/julia/

# Copy the shared libraries into the framework
install-libs: | $(framework_destdirs)
	cp $(build_shlibdir)/libjulia.dylib $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/$(IOS_FRAMEWORK_NAME)
	@# Copy internal libraries alongside the framework binary
	cp $(build_shlibdir)/libjulia-internal.dylib $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/
	cp $(build_shlibdir)/libjulia-codegen.dylib $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/
	@# Fix install names for iOS
	install_name_tool -id @rpath/$(IOS_FRAMEWORK_DIR)/$(IOS_FRAMEWORK_NAME) \
		$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)/$(IOS_FRAMEWORK_NAME)

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
	@echo "iOS framework built successfully:"
	@echo "  $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)"
	@echo ""

clean:
	rm -rf $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)

.PHONY: default framework build-julia install-headers install-libs codesign clean
