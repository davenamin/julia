# Define a set of targets for downloading, caching, and building the source of
# a stdlib library. The commit and git branch should be defined in a file
# $stdlib_name.version in the current directory. See the git-external macro for
# additional documentation.
#
# Parameters to the stdlib-external macro:
#
#   $1 = stdlib_name
#   $2 = var_prefix (by convention, use upper cased stdlib_name)

include $(JULIAHOME)/deps/tools/git-external.mk

define stdlib-external

$$(eval $$(call git-external,$1,$2,,,$$(BUILDDIR)))

# Patches for a vendored stdlib.  `stdlib/$1.version` pins an upstream commit,
# so a change needed inside an external stdlib lives in
# stdlib/patches/$1-*.patch and is applied here, in sorted order, right after
# extraction -- before `build-compiled`, which `install-$1` waits on, so the
# sysimage build reads the patched sources.
#
# These are in stdlib/patches/ rather than deps/patches/ because the two
# namespaces overlap: deps/patches/SuiteSparse-shlib.patch belongs to the
# libsuitesparse dependency, while SuiteSparse is also an external stdlib.
#
# As elsewhere in the build, the patch files are not prerequisites of the
# stamp: `patch` cannot re-apply to a patched tree, so editing one needs
# `make distclean-$1` to re-extract first.
$2_PATCHES := $$(sort $$(wildcard $$(SRCDIR)/patches/$1-*.patch))

$$(BUILDDIR)/$$($2_SRC_DIR)/source-patched: $$(BUILDDIR)/$$($2_SRC_DIR)/source-extracted
	@set -e; for p in $$($2_PATCHES); do \
		echo "Applying $$$$(basename $$$$p) to $1"; \
		(cd $$(dir $$@) && patch -p1 -f) < $$$$p; \
	done
	echo 1 > $$@

$$(BUILDDIR)/$$($2_SRC_DIR)/build-compiled: $$(BUILDDIR)/$$($2_SRC_DIR)/source-patched
	@# no build steps
	echo 1 > $$@
$$(eval $$(call symlink_install,$$$$(VERSDIR)/$1,$$$$($2_SRC_DIR),$$$$(build_datarootdir)/julia/stdlib))
clean-$1:
	-rm -f $$(BUILDDIR)/$$($2_SRC_DIR)/build-compiled
get-$1: $$($2_SRC_FILE)
extract-$1: $$(BUILDDIR)/$$($2_SRC_DIR)/source-extracted
patch-$1: $$(BUILDDIR)/$$($2_SRC_DIR)/source-patched
configure-$1: patch-$1
compile-$1: $$(BUILDDIR)/$$($2_SRC_DIR)/build-compiled
install-$1: install-$$(VERSDIR)/$1
uninstall-$1: uninstall-$$(VERSDIR)/$1
reinstall-$1: reinstall-$$(VERSDIR)/$1
version-check-$1: version-check-$$(VERSDIR)/$1
clean-$1: clean-$$(VERSDIR)/$1
.PHONY: $(addsuffix -$1,get extract patch configure compile install uninstall reinstall clean)
endef
