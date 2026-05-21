#!/usr/bin/env bash
# resign-internal-dylibs.sh — re-sign every internal dylib inside the
# embedded Julia.framework with the app's signing identity.
#
# Why this exists:
#   Xcode's "Embed & Sign" build phase signs the embedded framework's root
#   binary, but does NOT recurse into the framework's internal dylibs
#   (libLLVM, libopenblas, libgmp, libpcre2-8, sys.dylib, ...).  Those
#   dylibs keep whatever signature they had at framework build time.  Our
#   framework build defaults to ad-hoc signing (`-`), which AMFI accepts
#   on the iOS simulator but rejects on device and in App Store review.
#
#   This script walks the embedded framework, re-signs every internal
#   dylib with the app's identity ($EXPANDED_CODE_SIGN_IDENTITY), and
#   then re-signs the framework root so its CodeResources reflects the
#   updated internal signatures.
#
# How to use:
#   Add a Run Script build phase to your Xcode target, placed AFTER
#   "Embed Frameworks", with this script as the command:
#
#     "${SRCROOT}/path/to/Julia.framework-tools/resign-internal-dylibs.sh"
#
#   ("Based on dependency analysis" can be unchecked; this script needs to
#   run every build.)
#
#   The script reads the following Xcode-provided environment variables:
#     - BUILT_PRODUCTS_DIR
#     - FRAMEWORKS_FOLDER_PATH
#     - EXPANDED_CODE_SIGN_IDENTITY
#
# Alternative (skip this script entirely):
#   Build the framework with a real Apple Developer identity at framework
#   build time instead of ad-hoc.  Then Xcode's Embed phase signs the
#   root with the same identity and the internal dylibs already match:
#
#     make IOS=1 ios-framework \
#       DARWIN_CODESIGN_KEYCHAIN_IDENTITY="Apple Development: Your Name (TEAMID)"

set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?must be set by Xcode}"
: "${FRAMEWORKS_FOLDER_PATH:?must be set by Xcode}"
: "${EXPANDED_CODE_SIGN_IDENTITY:?must be set by Xcode}"

FRAMEWORK_NAME="${1:-Julia}"
FW="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/${FRAMEWORK_NAME}.framework"

if [[ ! -d "$FW" ]]; then
    echo "error: ${FRAMEWORK_NAME}.framework not found at $FW" >&2
    exit 1
fi

echo "Re-signing ${FRAMEWORK_NAME}.framework internal dylibs with identity: $EXPANDED_CODE_SIGN_IDENTITY"

# Sign every internal dylib (skip symlinks — codesign on a symlink
# follows it and signs the underlying file, so we'd sign the same binary
# multiple times under different names).
find "$FW" -maxdepth 1 -type f -name '*.dylib' -print0 |
while IFS= read -r -d '' lib; do
    echo "  signing $(basename "$lib")"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
             --preserve-metadata=identifier,entitlements,flags \
             --timestamp=none \
             "$lib"
done

# Re-sign the framework root so _CodeSignature/CodeResources picks up
# the new internal signatures.
echo "  re-signing ${FRAMEWORK_NAME}.framework"
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
         --preserve-metadata=identifier,entitlements,flags \
         --timestamp=none \
         "$FW"

echo "Done."
