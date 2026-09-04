#!/bin/sh
#
# build_utils.sh - assemble the CP/M host-transfer utilities W8.COM and R8.COM.
#
# Usage: tools/build_utils.sh
# Output: build/utils/{w8,r8}.com
#
# These belong to the INTERFACE version, not to a RomWBW version: they talk to
# the emulator's HBIOS host-file extension block (0xE1-0xEA), which RomWBW
# knows nothing about.  One build serves every RomWBW release, which is why
# this script takes no version argument.
#
# No ORG in either source.  ul80 bases a .COM at 0100h by itself; an ORG on top
# of that leaves 256 leading NOPs and a program that runs off the end of its
# own code.

set -eu
. "$(dirname "$0")/common.sh"

need_tools "$UM80" "$UL80"

OUT="$BUILD/utils"
rm -rf "$OUT"
mkdir -p "$OUT"

for util in w8 r8; do
    src="$ROOT/src/$util.asm"
    [ -f "$src" ] || die "$src does not exist"
    if ! "$UM80" -o "$OUT/$util.rel" "$src" >"$OUT/$util.log" 2>&1; then
        sed 's/^/      /' "$OUT/$util.log" >&2
        die "src/$util.asm does not assemble"
    fi
    if ! "$UL80" -o "$OUT/$util.com" "$OUT/$util.rel" >>"$OUT/$util.log" 2>&1; then
        sed 's/^/      /' "$OUT/$util.log" >&2
        die "src/$util.asm assembles but does not link"
    fi
    note "$(printf '%-8s %7s bytes  %s' "$util.com" "$(filesize "$OUT/$util.com")" "$(sha256of "$OUT/$util.com" | cut -c1-16)")"
done

# W8 must probe HBF_HOST_CAPS (0xE9) before it hands a host path to the
# emulator, and refuse if CAP_SAFE_PATHS is clear.  The probe assembles to
# `ld b,0E9h / rst 8` = 06 e9 cf.  A W8 without it is syntactically fine and
# semantically obsolete - no hash can tell you that, only this can.
if ! od -An -tx1 -v "$OUT/w8.com" | tr -s ' ' | tr ' ' '\n' | tr -d '\n' |
     grep -q "06e9cf"; then
    die "w8.com does not contain the HBF_HOST_CAPS interlock (06 e9 cf).
       Either src/w8.asm lost the probe or the assembler miscompiled it.
       Shipping this would let an old emulator take an unchecked host path."
fi
note "w8.com carries the HBF_HOST_CAPS interlock (06 e9 cf)"

rm -f "$OUT"/*.rel "$OUT"/*.sym
echo "PASS: host-transfer utilities built in $OUT"
