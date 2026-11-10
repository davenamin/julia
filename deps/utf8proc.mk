## UTF8PROC ##
UTF8PROC_GIT_URL := https://github.com/JuliaLang/utf8proc.git
UTF8PROC_TAR_URL = https://api.github.com/repos/JuliaLang/utf8proc/tarball/$1
$(eval $(call git-external,utf8proc,UTF8PROC,,,$(BUILDDIR)))

UTF8PROC_OBJ_LIB    := $(build_libdir)/libutf8proc.a
UTF8PROC_OBJ_HEADER := $(build_includedir)/utf8proc.h
UTF8PROC_CFLAGS     := -O2 $(SANITIZE_OPTS)
UTF8PROC_MFLAGS     := CC="$(CC)" CFLAGS="$(CFLAGS) $(UTF8PROC_CFLAGS)" PICFLAG="$(fPIC)" AR="$(AR)"
UTF8PROC_BUILDDIR   := $(BUILDDIR)/$(UTF8PROC_SRC_DIR)

$(UTF8PROC_BUILDDIR)/build-compiled: $(UTF8PROC_BUILDDIR)/source-extracted
	$(MAKE) -C $(dir $<) $(UTF8PROC_MFLAGS) libutf8proc.a
	echo 1 > $@

$(UTF8PROC_BUILDDIR)/build-checked: $(UTF8PROC_BUILDDIR)/build-compiled
ifeq ($(OS),$(BUILD_OS))
	$(MAKE) -C $(dir $@) $(UTF8PROC_MFLAGS) check
endif
	echo 1 > $@

define UTF8PROC_INSTALL
	mkdir -p $2/$$(build_includedir) $2/$$(build_libdir)
	cp $1/utf8proc.h $2/$$(build_includedir)
	cp $1/libutf8proc.a $2/$$(build_libdir)
endef
$(eval $(call staged-install, \
	utf8proc,$(UTF8PROC_SRC_DIR), \
	UTF8PROC_INSTALL,,,))

clean-utf8proc:
	-rm -f $(BUILDDIR)/$(UTF8PROC_SRC_DIR)/build-compiled
	-$(MAKE) -C $(BUILDDIR)/$(UTF8PROC_SRC_DIR) clean

## Host-native utf8proc for cross-compilation host tools (e.g. flisp) ##
ifeq ($(USE_CROSS_FLISP), 1)
HOST_UTF8PROC_BUILDDIR := $(BUILDDIR)/host-$(UTF8PROC_SRC_DIR)

$(HOST_UTF8PROC_BUILDDIR)/source-copied: $(UTF8PROC_BUILDDIR)/source-extracted
	mkdir -p $(HOST_UTF8PROC_BUILDDIR)
	cp $(UTF8PROC_BUILDDIR)/utf8proc.c $(UTF8PROC_BUILDDIR)/utf8proc.h \
		$(UTF8PROC_BUILDDIR)/utf8proc_data.c $(UTF8PROC_BUILDDIR)/Makefile \
		$(HOST_UTF8PROC_BUILDDIR)/
	echo 1 > $@

$(HOST_UTF8PROC_BUILDDIR)/build-compiled: $(HOST_UTF8PROC_BUILDDIR)/source-copied
	$(MAKE) -C $(HOST_UTF8PROC_BUILDDIR) \
		CC="$(HOSTCC)" CFLAGS="$(HOST_CFLAGS) -O2" PICFLAG="$(fPIC)" AR="$(AR)" \
		libutf8proc.a
	echo 1 > $@

install-host-utf8proc: $(HOST_UTF8PROC_BUILDDIR)/build-compiled
	mkdir -p $(build_prefix)/host/lib $(build_prefix)/host/include
	cp $(HOST_UTF8PROC_BUILDDIR)/libutf8proc.a $(build_prefix)/host/lib/
	cp $(HOST_UTF8PROC_BUILDDIR)/utf8proc.h $(build_prefix)/host/include/

clean-host-utf8proc:
	rm -rf $(HOST_UTF8PROC_BUILDDIR)
endif

get-utf8proc: $(UTF8PROC_SRC_FILE)
extract-utf8proc: $(UTF8PROC_BUILDDIR)/source-extracted
configure-utf8proc: extract-utf8proc
compile-utf8proc: $(UTF8PROC_BUILDDIR)/build-compiled
# utf8proc tests disabled since they require a download
fastcheck-utf8proc: #check-utf8proc
check-utf8proc: $(UTF8PROC_BUILDDIR)/build-checked
