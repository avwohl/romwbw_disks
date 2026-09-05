#!/bin/sh
#
# verify_release.sh - check a built tree against its own catalog.
#
# Usage: tools/verify_release.sh [romwbw-version ...]   (default: all)
#
# Run after tools/build_all.sh and again after publishing.  It re-derives every
# claim the catalog makes rather than trusting the generator, so a bug in
# gen_catalog.py cannot certify itself.
#
# What it checks, and why each one exists:
#
#  1. Every file the catalog names is present, is the size it says, and hashes
#     to the sha256 it says.  The catalog this repo replaces had hand-typed
#     hashes, and shipping it safely needed a human to remember a pre-flight
#     check.
#
#  2. Every ROM's HCB at 0x103 reads 'W' 0xA8 then the two packed version bytes
#     for its RomWBW release.  Those four bytes are what the emulator and every
#     client read to decide what a ROM is.  emu_validate_rom_hcb refuses a ROM
#     with no readable HCB, and refuses one naming a release that core has not
#     been checked against, so a ROM that fails this check here is one no
#     client can boot.
#
#  3. Every bootable image's CBIOS banner names the same release.  A ROM and a
#     disk from different releases make the guest print
#     "*** WARNING: HBIOS/CBIOS Version Mismatch ***" at boot.  Upstream
#     compares major.minor only, so this catches 3.5.x against 3.6.x - and a
#     "-dev.NN" banner, which no version-byte check can see because a dev
#     snapshot carries the same HCB bytes as the release it precedes.
#
#  4. Every image the catalog says carries host transfer really has w8.com and
#     r8.com in its directory, and that w8.com still contains the
#     HBF_HOST_CAPS interlock (06 e9 cf).  That last one catches a class of bug
#     no hash can: a .COM that is syntactically fine and semantically obsolete,
#     which would hand an old emulator an unchecked host path.

set -eu
. "$(dirname "$0")/common.sh"

if [ "$#" -gt 0 ]; then
    VERSIONS="$*"
    SCOPED=1
else
    VERSIONS="$(cd "$ROOT/versions" && ls -d */ 2>/dev/null | tr -d '/' | sort | tr '\n' ' ')"
    SCOPED=0
fi
[ -n "$VERSIONS" ] || die "no RomWBW versions found under $ROOT/versions"

rc=0
checked=0
for v in $VERSIONS; do
    tag="$(release_tag "$v")"
    dir="$BUILD/$tag"
    cat_json="$dir/catalog-$IFACE-$v.json"
    [ -f "$cat_json" ] || die "no catalog at $cat_json - run tools/build_all.sh $v"

    echo "=== $tag ==="
    if python3 "$ROOT/tools/verify_catalog.py" "$cat_json" "$dir"; then
        echo "PASS: $tag"
    else
        rc=1
    fi
    checked=$((checked + 1))
    echo
done

# "PASS: every artifact matches its catalog entry" having opened nothing is a
# claim, not a result.
[ "$checked" -gt 0 ] || die "verified nothing - no version had a built catalog"

# The index describes every version, so it can only be verified when every
# version is built.  Checking it after `verify_release.sh 3.5.1` in a tree
# where 3.6.0 is not built reported a failure about 3.6.0 and made publishing
# 3.5.1 alone impossible.
idx="$BUILD/catalog-$IFACE/index-$IFACE.json"
if [ "$SCOPED" = "1" ]; then
    echo "=== index ==="
    echo "  skipped: only $VERSIONS was requested, and the index covers every version"
    echo
elif [ -f "$idx" ]; then
    echo "=== index ==="
    python3 "$ROOT/tools/verify_catalog.py" --index "$idx" "$BUILD" || rc=1
    echo
fi

if [ "$rc" -eq 0 ]; then
    echo "PASS: every artifact matches its catalog entry"
else
    echo "FAIL: see above" >&2
fi
exit "$rc"
