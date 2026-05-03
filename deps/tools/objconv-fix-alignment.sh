#!/bin/sh
# Wrapper around objconv that fixes archive member alignment.
# Apple's ld (Xcode 15+) requires 8-byte alignment for 64-bit Mach-O
# members inside static archives.  objconv does not preserve this when
# rewriting archives for symbol renaming, producing the error:
#   ld: 64-bit mach-o member '...' not 8-byte aligned in '...'
#
# After running the real objconv, this script extracts the output
# archive and re-creates it with ar, which writes properly aligned
# members.
#
# Usage: objconv-fix-alignment.sh <real-objconv> [objconv-args...]

set -eu

REAL_OBJCONV="$1"
shift

"$REAL_OBJCONV" "$@"

for arg in "$@"; do
    case "$arg" in
        *.renamed)
            if [ -f "$arg" ]; then
                case "$arg" in
                    /*) _archive="$arg" ;;
                    *)  _archive="$(pwd)/$arg" ;;
                esac
                _tmpdir=$(mktemp -d)
                (cd "$_tmpdir" && ar x "$_archive" && rm "$_archive" && ar rcs "$_archive" *.o)
                rm -rf "$_tmpdir"
            fi
            ;;
    esac
done
