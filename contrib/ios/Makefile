JULIAHOME := $(abspath ../..)
include $(JULIAHOME)/Make.inc
include $(JULIAHOME)/deps/llvm-ver.make

# Build Julia as a set of iOS frameworks.
#
# iOS App Store rule: an app may only ship dynamic libraries as frameworks —
# one Mach-O binary per framework bundle, named by CFBundleExecutable.  Loose
# .dylib files anywhere in the app bundle are rejected at submission
# validation ("Your app cannot contain standalone executables or libraries").
# So instead of one Julia.framework containing every dependency dylib, this
# produces a Frameworks/ directory with one single-binary framework per
# library:
#
#   Frameworks/
#     Julia.framework/Julia              (libjulia, the loader; the only
#                                         framework with Headers/Modules —
#                                         the app links against this one)
#     libjulia-internal.framework/libjulia-internal
#     libjulia-codegen.framework/libjulia-codegen
#     JuliaSysimage.framework/JuliaSysimage   (the baked sysimage, sys.dylib)
#     libgmp.framework/libgmp
#     ... one per dependency dylib ...
#
# Framework names are the dylib base name with the extension and trailing
# numeric version components stripped (libgit2.1.6.dylib -> libgit2).  All
# inter-library references are rewritten to @rpath/<base>.framework/<base>,
# and each binary carries an extra LC_RPATH "@loader_path/.." so the set is
# self-contained once the frameworks are siblings.  Runtime dlopens by
# unix-style dylib name (JLL SONAME strings, Base ccalls) are mapped to the
# framework layout by an iOS-only fallback in src/dlload.c using the same
# name-stripping rule.  The loader's baked DEP_LIBS list is framework-aware
# via Make.inc (LOADER_BUILD_DEP_LIBS under IOS=1).
#
# Single-platform build (device or simulator):
#   make -C contrib/ios IOS=1 framework
#   make -C contrib/ios IOS=1 IOS_PLATFORM=iphonesimulator framework
#
# XCFrameworks (device + simulator combined, one per library):
#   contrib/ios/build-xcframework.sh builds both slices and runs
#   xcodebuild -create-xcframework once per framework; embed every produced
#   xcframework in the app ("Embed & Sign"), and link only Julia.xcframework.

default: framework

# Validate that IOS mode is enabled
ifneq ($(IOS), 1)
$(error iOS framework build requires IOS=1. Run: make -C contrib/ios IOS=1 framework)
endif

# The codesigning identity on Darwin.
DARWIN_CODESIGN_KEYCHAIN_IDENTITY ?= -

# iOS framework structure.  All frameworks (the main Julia one plus one per
# dependency dylib) are emitted side by side under Frameworks/.
IOS_FRAMEWORK_NAME ?= Julia
IOS_FRAMEWORK_BUNDLE_ID ?= org.julialang.julia
IOS_FRAMEWORK_DIR := $(IOS_FRAMEWORK_NAME).framework
IOS_FRAMEWORK_HEADERS := $(IOS_FRAMEWORK_DIR)/Headers
IOS_FRAMEWORK_MODULES := $(IOS_FRAMEWORK_DIR)/Modules

# Root output directory holding every emitted framework
IOS_FWKS_ROOT := $(DESTDIR)$(prefix)/Frameworks
# The main (linkable) framework
IOS_FWDIR := $(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_DIR)
# Framework bundle name for the baked sysimage (sys.dylib)
IOS_SYSIMAGE_FW := JuliaSysimage

# XCFramework output
IOS_XCFRAMEWORK_DIR := $(IOS_FRAMEWORK_NAME).xcframework

# Platform name for Info.plist — iPhoneOS or iPhoneSimulator
ifeq ($(IOS_PLATFORM),iphonesimulator)
IOS_PLIST_PLATFORM := iPhoneSimulator
else
IOS_PLIST_PLATFORM := iPhoneOS
endif
IOS_SDK_VERSION := $(shell xcrun --sdk $(IOS_PLATFORM) --show-sdk-version 2>/dev/null)

framework_destdirs := $(addprefix $(IOS_FWKS_ROOT)/,$(IOS_FRAMEWORK_DIR) $(IOS_FRAMEWORK_HEADERS) $(IOS_FRAMEWORK_HEADERS)/julia $(IOS_FRAMEWORK_HEADERS)/julia/uv $(IOS_FRAMEWORK_MODULES))

$(framework_destdirs):
	mkdir -p $@

# Build the Julia shared libraries (skip sysimg — it requires running the Julia
# executable, which is impossible during cross-compilation).
build-julia:
	$(MAKE) -C $(JULIAHOME) IOS=1 IOS_PLATFORM=$(IOS_PLATFORM) julia-src-release

# Generate Info.plist for the main iOS framework
$(IOS_FWDIR)/Info.plist: | $(framework_destdirs)
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
	/usr/libexec/PlistBuddy -x -c "Add :DTSDKName string $(IOS_PLATFORM)$(IOS_SDK_VERSION)" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily array" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily:0 integer 1" $@
	/usr/libexec/PlistBuddy -x -c "Add :UIDeviceFamily:1 integer 2" $@

# Generate the module map — use an umbrella header instead of an umbrella
# directory so that the module works reliably inside XCFrameworks (umbrella
# directories can fail to resolve after xcodebuild -create-xcframework
# repackages the framework).
$(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_MODULES)/module.modulemap: | $(framework_destdirs)
	@echo 'framework module $(IOS_FRAMEWORK_NAME) [extern_c] [system] {' > $@
	@echo '  umbrella header "$(IOS_FRAMEWORK_NAME).h"' >> $@
	@echo '  export *' >> $@
	@echo '}' >> $@

# Generate the umbrella header
$(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h: | $(framework_destdirs)
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
	cp $(build_includedir)/julia/*.h $(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_HEADERS)/julia/
	cp $(build_includedir)/julia/uv/*.h $(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_HEADERS)/julia/uv/
	sed -i '' -E 's|#[[:space:]]*include "uv/|#include "|g' $(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_HEADERS)/julia/uv/*.h

# Bundle every shared library as its own single-binary framework under
# $(IOS_FWKS_ROOT), per the App Store rule described at the top of this file.
#
# Naming:
#   - libjulia  ->  $(IOS_FRAMEWORK_NAME).framework/$(IOS_FRAMEWORK_NAME)
#   - sys.dylib ->  $(IOS_SYSIMAGE_FW).framework/$(IOS_SYSIMAGE_FW)
#   - libjulia-internal / libjulia-codegen -> <name-up-to-first-dot>
#   - everything else -> LC_ID_DYLIB leaf (falling back to the file name)
#     with ".dylib" and trailing numeric version components stripped, e.g.
#     libgit2.1.6.dylib -> libgit2.  Deriving the name from the install-name
#     id guarantees that rewriting consumers' LC_LOAD_DYLIB entries (which
#     record the dep's id) by the same rule lands on the framework we
#     created.  The same stripping rule is applied at runtime by the dlopen
#     fallback in src/dlload.c, so JLL SONAME strings (@rpath/libgmp.10.dylib)
#     and plain ccall names (libgmp) resolve to the same framework.
#
# Symlinks and alias copies are gone entirely: every reference funnels
# through the strip rule to a single canonical framework, which is also
# what App Store validation requires (symlinks in bundles are rejected).
#
# Install-name surgery on every framework binary:
#   - LC_ID_DYLIB               ->  @rpath/<base>.framework/<base>
#   - every LC_LOAD_DYLIB that is not a system path (/usr/lib, /System) and
#     not already framework-style -> @rpath/<mapped-base>.framework/<mapped-base>.
#     This includes ABSOLUTE build-tree paths: autotools/CMake-built deps
#     stamp them (e.g. libgmpxx recorded /.../build-ios-device/usr/lib/
#     libgmp.10.dylib, which crashed app launch with dyld "Library not
#     loaded" on device).
#   - add LC_RPATH @loader_path/..  (frameworks are siblings, so each binary
#     can resolve the others without relying on the app's rpath setup)
# A verification pass then re-scans every emitted binary and FAILS the build
# if any load command remains that is neither a system path nor a reference
# to a framework that was actually emitted — so a dep with a surprising
# install-name shape breaks here, at build time, not at app launch.
#
# Not bundled: libgmpxx (GMP's C++ bindings), libLTO and libRemarks (LLVM
# tooling libs).  Nothing in the Julia runtime references any of them, they
# add three frameworks and real megabytes to every app, and libgmpxx was
# the absolute-path crasher above.
#
# Each dependency framework gets a minimal Info.plist: CFBundleExecutable
# must match the binary, and MinimumOSVersion / platform keys are required
# at submission validation.  CFBundleIdentifier forbids '_' — sanitize it
# (the framework/binary name itself keeps the underscore, e.g.
# libopenblas64_).
#
# Every framework also gets a PrivacyInfo.xcprivacy privacy manifest —
# required since May 2024 for binaries using Apple's "required reason" APIs
# (rejections arrive as ITMS-91053 mails).  The Julia runtime demonstrably
# uses three declared categories, so declare them with the standard
# non-tracking reason codes:
#   - FileTimestamp / C617.1: stat & friends throughout base/stat.jl,
#     used on files inside the app container (depot, resources tree).
#   - DiskSpace / E174.1: Base.diskstat -> uv_fs_statfs (base/file.jl),
#     checking available space before writes.
#   - SystemBootTime / 35F9.1: Sys.uptime -> uv_uptime (base/sysinfo.jl)
#     and mach-time clocks, used to measure elapsed time in-process.
# The same manifest is stamped into every framework: Apple's scanner checks
# per-binary, over-declaring is harmless, and per-library symbol analysis
# would be fragile.  NSPrivacyTracking=false and empty collected-data —
# the runtime phones nothing home.  Apps whose OWN code uses more
# categories declare those in the app target's manifest, not here.
# See contrib/ios/APPSTORE.md.
install-libs: | $(framework_destdirs)
	@set -e; \
	strip_base() { printf '%s' "$$1" | sed -E -e 's/\.dylib$$//' -e ':a' -e 's/\.[0-9]+$$//' -e 'ta'; }; \
	write_privacy_manifest() { \
		fw_dir="$$1"; \
		printf '%s\n' \
			'<?xml version="1.0" encoding="UTF-8"?>' \
			'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
			'<plist version="1.0">' \
			'<dict>' \
			'  <key>NSPrivacyTracking</key><false/>' \
			'  <key>NSPrivacyTrackingDomains</key><array/>' \
			'  <key>NSPrivacyCollectedDataTypes</key><array/>' \
			'  <key>NSPrivacyAccessedAPITypes</key>' \
			'  <array>' \
			'    <dict>' \
			'      <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string>' \
			'      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>C617.1</string></array>' \
			'    </dict>' \
			'    <dict>' \
			'      <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string>' \
			'      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>E174.1</string></array>' \
			'    </dict>' \
			'    <dict>' \
			'      <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategorySystemBootTime</string>' \
			'      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>35F9.1</string></array>' \
			'    </dict>' \
			'  </array>' \
			'</dict>' \
			'</plist>' > "$$fw_dir/PrivacyInfo.xcprivacy"; \
	}; \
	write_dep_plist() { \
		fw_dir="$$1"; base="$$2"; \
		ident=$$(printf '%s' "$$base" | tr '_' '-' | sed -E 's/-+$$//'); \
		{ \
			printf '%s\n' \
				'<?xml version="1.0" encoding="UTF-8"?>' \
				'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
				'<plist version="1.0">' \
				'<dict>'; \
			printf '  <key>%s</key><string>%s</string>\n' \
				CFBundleName "$$base" \
				CFBundleExecutable "$$base" \
				CFBundleIdentifier "org.julialang.$$ident" \
				CFBundleVersion "$(JULIA_MAJOR_VERSION).$(JULIA_MINOR_VERSION).$(JULIA_PATCH_VERSION)" \
				CFBundleShortVersionString "$(JULIA_MAJOR_VERSION).$(JULIA_MINOR_VERSION).$(JULIA_PATCH_VERSION)" \
				CFBundlePackageType FMWK \
				CFBundleInfoDictionaryVersion 6.0 \
				MinimumOSVersion "$(IOS_VERSION_MIN)" \
				DTPlatformName "$(IOS_PLATFORM)" \
				DTSDKName "$(IOS_PLATFORM)$(IOS_SDK_VERSION)"; \
			printf '%s\n' \
				'  <key>CFBundleSupportedPlatforms</key><array><string>$(IOS_PLIST_PLATFORM)</string></array>' \
				'  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>' \
				'</dict>' \
				'</plist>'; \
		} > "$$fw_dir/Info.plist"; \
	}; \
	echo "Bundling per-dylib frameworks into $(IOS_FWKS_ROOT)"; \
	rm -rf "$(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)"; \
	for fw in "$(IOS_FWKS_ROOT)"/*.framework; do \
		[ -e "$$fw" ] || continue; \
		case "$$(basename "$$fw")" in \
			$(IOS_FRAMEWORK_DIR)) ;; \
			*) rm -rf "$$fw" ;; \
		esac; \
	done; \
	rm -f "$(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)" "$(IOS_FWDIR)"/*.$(SHLIB_EXT); \
	cp -fL "$(build_shlibdir)/libjulia.$(JL_MAJOR_MINOR_SHLIB_EXT)" "$(IOS_FWDIR)/$(IOS_FRAMEWORK_NAME)"; \
	for lib in "$(build_shlibdir)"/*.$(SHLIB_EXT); do \
		[ -f "$$lib" ] && [ ! -L "$$lib" ] || continue; \
		name=$$(basename "$$lib"); \
		case "$$name" in \
			libjulia.*|libccalltest*|libccalllazy*|libllvmcalltest*) continue ;; \
			libgmpxx*|libLTO*|libRemarks*) continue ;; \
		esac; \
		case "$$name" in \
			libjulia-internal*|libjulia-codegen*) base="$${name%%.*}" ;; \
			*) \
				id=$$(otool -D "$$lib" 2>/dev/null | sed -n '2p'); \
				leaf="$${id##*/}"; \
				[ -n "$$leaf" ] || leaf="$$name"; \
				base=$$(strip_base "$$leaf") ;; \
		esac; \
		mkdir -p "$(IOS_FWKS_ROOT)/$$base.framework"; \
		cp -f "$$lib" "$(IOS_FWKS_ROOT)/$$base.framework/$$base"; \
		write_dep_plist "$(IOS_FWKS_ROOT)/$$base.framework" "$$base"; \
	done; \
	if [ -f "$(build_private_shlibdir)/sys.$(SHLIB_EXT)" ]; then \
		mkdir -p "$(IOS_FWKS_ROOT)/$(IOS_SYSIMAGE_FW).framework"; \
		cp -fL "$(build_private_shlibdir)/sys.$(SHLIB_EXT)" \
			"$(IOS_FWKS_ROOT)/$(IOS_SYSIMAGE_FW).framework/$(IOS_SYSIMAGE_FW)"; \
		write_dep_plist "$(IOS_FWKS_ROOT)/$(IOS_SYSIMAGE_FW).framework" "$(IOS_SYSIMAGE_FW)"; \
	fi; \
	for fw in "$(IOS_FWKS_ROOT)"/*.framework; do \
		fwname=$$(basename "$$fw" .framework); \
		bin="$$fw/$$fwname"; \
		write_privacy_manifest "$$fw"; \
		[ -f "$$bin" ] || continue; \
		install_name_tool -id "@rpath/$$fwname.framework/$$fwname" "$$bin" 2>/dev/null || true; \
		install_name_tool -add_rpath "@loader_path/.." "$$bin" 2>/dev/null || true; \
		for dep in $$(otool -L "$$bin" 2>/dev/null | tail -n +2 | awk '{print $$1}'); do \
			case "$$dep" in \
				/usr/lib/*|/System/*) continue ;; \
				@rpath/*.framework/*) continue ;; \
			esac; \
			leaf="$${dep##*/}"; \
			case "$$leaf" in \
				libjulia.$(SHLIB_EXT)|libjulia.[0-9]*.$(SHLIB_EXT)) \
					tgt="$(IOS_FRAMEWORK_NAME)" ;; \
				libjulia-internal*|libjulia-codegen*) \
					tgt="$${leaf%%.*}" ;; \
				*) \
					tgt=$$(strip_base "$$leaf") ;; \
			esac; \
			install_name_tool -change "$$dep" "@rpath/$$tgt.framework/$$tgt" "$$bin" 2>/dev/null || true; \
		done; \
	done; \
	fail=0; \
	for fw in "$(IOS_FWKS_ROOT)"/*.framework; do \
		fwname=$$(basename "$$fw" .framework); \
		bin="$$fw/$$fwname"; \
		[ -f "$$bin" ] || continue; \
		for dep in $$(otool -L "$$bin" 2>/dev/null | tail -n +2 | awk '{print $$1}'); do \
			case "$$dep" in \
				/usr/lib/*|/System/*) ;; \
				@rpath/*.framework/*) \
					tfw="$${dep#@rpath/}"; tfw="$${tfw%%/*}"; \
					[ -d "$(IOS_FWKS_ROOT)/$$tfw" ] || { \
						echo "ERROR: $$fwname references '$$dep' but" \
						     "$$tfw is not among the emitted frameworks" >&2; \
						fail=1; }; ;; \
				*) echo "ERROR: $$fwname still references '$$dep'," \
				        "which cannot resolve on a device" >&2; fail=1 ;; \
			esac; \
		done; \
	done; \
	[ "$$fail" = 0 ] || { echo "ERROR: unresolvable load commands remain (see above)." >&2; exit 1; }

# Codesign every framework.
#
# Apple's AMFI (Apple Mobile File Integrity) checks every Mach-O image on
# dlopen() and refuses to map any binary without its own valid embedded
# LC_CODE_SIGNATURE.  With the one-binary-per-framework layout, signing each
# framework bundle signs its (only) binary and seals the bundle, so a single
# pass over the frameworks covers everything.  Xcode's "Embed & Sign" re-signs
# each embedded framework with the app's identity at build time regardless.
codesign:
	@for fw in "$(IOS_FWKS_ROOT)"/*.framework; do \
		[ -d "$$fw" ] || continue; \
		codesign -s "$(DARWIN_CODESIGN_KEYCHAIN_IDENTITY)" -f \
			--timestamp=none "$$fw" || exit 1; \
	done

# Explicit inter-step dependencies so the framework target is safe under
# `make -j` (prerequisites of a single target carry no ordering guarantee):
# libraries must exist before codesign runs, and the built tree must exist
# before anything is copied out of it.
install-headers install-libs: build-julia
codesign: install-libs install-headers \
	$(IOS_FWDIR)/Info.plist \
	$(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_MODULES)/module.modulemap \
	$(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h

framework: build-julia \
	$(IOS_FWDIR)/Info.plist \
	$(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_MODULES)/module.modulemap \
	$(IOS_FWKS_ROOT)/$(IOS_FRAMEWORK_HEADERS)/$(IOS_FRAMEWORK_NAME).h \
	install-headers install-libs codesign
	@echo ""
	@echo "iOS frameworks built successfully ($(IOS_PLATFORM)):"
	@echo "  $(IOS_FWKS_ROOT)"
	@echo ""
	@echo "To embed in an Xcode app:"
	@echo "  1. Add EVERY framework under $(IOS_FWKS_ROOT) to the target's"
	@echo "     'Frameworks, Libraries, and Embedded Content' list with"
	@echo "     'Embed & Sign' selected.  App Store rules require each dylib"
	@echo "     to be its own framework — none of them are optional."
	@echo "  2. Only $(IOS_FRAMEWORK_NAME).framework carries headers; it is the"
	@echo "     one the app compiles and links against."
	@echo "  3. Xcode's Embed phase re-signs each framework with the app's"
	@echo "     identity, so the ad-hoc build signature does not need to match."
	@echo ""
	@echo "For a device+simulator XCFramework set, use contrib/ios/build-xcframework.sh."
	@echo "Before submitting to the App Store, read contrib/ios/APPSTORE.md."
	@echo ""

# XCFrameworks — combine pre-built device and simulator framework SETS.
#
# Set IOS_DEVICE_FRAMEWORKS and IOS_SIM_FRAMEWORKS to the Frameworks/
# directories of the respective slices (each containing Julia.framework
# plus one framework per dependency).  One xcframework is produced per
# framework name, into $(DESTDIR)$(prefix)/xcframeworks/.  Every framework
# present in the device set must exist in the simulator set too.
# contrib/ios/build-xcframework.sh drives this end to end.
IOS_DEVICE_FRAMEWORKS ?=
IOS_SIM_FRAMEWORKS ?=

xcframework:
	@test -n "$(IOS_DEVICE_FRAMEWORKS)" || \
		{ echo "Error: IOS_DEVICE_FRAMEWORKS not set." \
		       "Set it to the iphoneos slice's Frameworks directory."; exit 1; }
	@test -n "$(IOS_SIM_FRAMEWORKS)" || \
		{ echo "Error: IOS_SIM_FRAMEWORKS not set." \
		       "Set it to the iphonesimulator slice's Frameworks directory."; exit 1; }
	@test -d "$(IOS_DEVICE_FRAMEWORKS)" || \
		{ echo "Error: device frameworks not found at $(IOS_DEVICE_FRAMEWORKS)"; exit 1; }
	@test -d "$(IOS_SIM_FRAMEWORKS)" || \
		{ echo "Error: simulator frameworks not found at $(IOS_SIM_FRAMEWORKS)"; exit 1; }
	@set -e; \
	outdir="$(DESTDIR)$(prefix)/xcframeworks"; \
	rm -rf "$$outdir"; mkdir -p "$$outdir"; \
	for fw in "$(IOS_DEVICE_FRAMEWORKS)"/*.framework; do \
		name=$$(basename "$$fw" .framework); \
		simfw="$(IOS_SIM_FRAMEWORKS)/$$name.framework"; \
		if [ ! -d "$$simfw" ]; then \
			echo "Error: $$name.framework exists in the device set but not the simulator set"; \
			exit 1; \
		fi; \
		xcodebuild -create-xcframework \
			-framework "$$fw" \
			-framework "$$simfw" \
			-output "$$outdir/$$name.xcframework"; \
	done
	@echo ""
	@echo "XCFrameworks built successfully:"
	@echo "  $(DESTDIR)$(prefix)/xcframeworks"
	@echo ""

clean:
	rm -rf $(IOS_FWKS_ROOT)
	rm -rf $(DESTDIR)$(prefix)/$(IOS_FRAMEWORK_DIR)
	rm -rf $(DESTDIR)$(prefix)/$(IOS_XCFRAMEWORK_DIR)
	rm -rf $(DESTDIR)$(prefix)/xcframeworks

.PHONY: default framework build-julia install-headers install-libs codesign xcframework clean
