## libffi ##
#
# Only built for iOS.  The interpreter performs `ccall` through `ffi_call`
# there (src/interpreter-ccall.c), because a device cannot map executable
# memory and so cannot use the compiler.  `ffi_call` needs no executable
# memory — only `ffi_prep_closure_loc` does, and that is the `@cfunction`
# direction, which stays unsupported.
#
# Static, and linked into libjulia-internal rather than shipped as its own
# framework: an App Store bundle may not contain loose dylibs, so every shared
# library costs another framework, and this one has a single consumer.
#
# MIT-licensed, so it does not disturb the `USE_GPL_LIBS = 0` default.
include $(SRCDIR)/libffi.version

LIBFFI_CONFIGURE_OPTS := $(CONFIGURE_COMMON)
LIBFFI_CONFIGURE_OPTS += --enable-static --disable-shared
# Nothing here calls into the closure API, and building it is what pulls in
# the executable-memory machinery that iOS forbids in the first place.
LIBFFI_CONFIGURE_OPTS += --disable-exec-static-tramp
LIBFFI_CONFIGURE_OPTS += --disable-docs --disable-multi-os-directory
ifeq ($(IOS), 1)
# `CONFIGURE_COMMON` only passes `--host` when `XC_HOST` is set, which the iOS
# block does not use; without it configure probes the macOS host it is running
# on and picks the wrong ABI sources.
LIBFFI_CONFIGURE_OPTS += --host=aarch64-apple-darwin
endif

$(SRCCACHE)/libffi-$(LIBFFI_VER).tar.gz: | $(SRCCACHE)
	$(JLDOWNLOAD) $@ https://github.com/libffi/libffi/releases/download/v$(LIBFFI_VER)/libffi-$(LIBFFI_VER).tar.gz

$(SRCCACHE)/libffi-$(LIBFFI_VER)/source-extracted: $(SRCCACHE)/libffi-$(LIBFFI_VER).tar.gz
	$(JLCHECKSUM) $<
	cd $(dir $<) && $(TAR) zxf $<
	touch -c $(SRCCACHE)/libffi-$(LIBFFI_VER)/configure # old target
	echo 1 > $@

checksum-libffi: $(SRCCACHE)/libffi-$(LIBFFI_VER).tar.gz
	$(JLCHECKSUM) $<

$(BUILDDIR)/libffi-$(LIBFFI_VER)/build-configured: $(SRCCACHE)/libffi-$(LIBFFI_VER)/source-extracted
	mkdir -p $(dir $@)
	cd $(dir $@) && \
	$(dir $<)/configure $(LIBFFI_CONFIGURE_OPTS)
	echo 1 > $@

$(BUILDDIR)/libffi-$(LIBFFI_VER)/build-compiled: $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-configured
	$(MAKE) -C $(dir $<)
	echo 1 > $@

$(BUILDDIR)/libffi-$(LIBFFI_VER)/build-checked: $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-compiled
ifeq ($(OS),$(BUILD_OS))
	$(MAKE) -C $(dir $@) check
endif
	echo 1 > $@

$(eval $(call staged-install, \
	libffi,libffi-$(LIBFFI_VER), \
	MAKE_INSTALL,,,))

clean-libffi:
	-rm -f $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-configured $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-compiled
	-$(MAKE) -C $(BUILDDIR)/libffi-$(LIBFFI_VER) clean

distclean-libffi:
	rm -rf $(SRCCACHE)/libffi-$(LIBFFI_VER).tar.gz \
		$(SRCCACHE)/libffi-$(LIBFFI_VER) \
		$(BUILDDIR)/libffi-$(LIBFFI_VER)

get-libffi: $(SRCCACHE)/libffi-$(LIBFFI_VER).tar.gz
extract-libffi: $(SRCCACHE)/libffi-$(LIBFFI_VER)/source-extracted
configure-libffi: $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-configured
compile-libffi: $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-compiled
fastcheck-libffi: check-libffi
check-libffi: $(BUILDDIR)/libffi-$(LIBFFI_VER)/build-checked
