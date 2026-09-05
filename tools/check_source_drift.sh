#!/bin/sh
#
# check_source_drift.sh - do this repository's Z80 sources still agree with
# romwbw_emu's?
#
# Four files exist in both trees, and nothing until now compared them.  That is
# the price of the two repositories building independently: romwbw_emu still
# builds its own bundled ROM and its own two tracked disk images from src/, and
# this repository builds the published artifacts from its own copies.  Neither
# is a symlink to the other and neither is generated, so a fix applied to one
# and not the other is invisible until a user hits it.
#
#   src/r8.asm       identical in both, and must stay so
#   src/w8.asm       identical in both, and must stay so
#   src/emu_rom.asm  identical in both, and must stay so
#   src/emu_hbios.asm  DELIBERATELY DIFFERENT - see below
#
# emu_hbios.asm is the interesting one.  romwbw_emu hardcodes `db 035h` / `db
# 010h` at both stamp sites, because that tree is cut from one release.  This
# repository cannot: it builds a ROM for any RomWBW release, so the same two
# sites read RMV_VER / RMV_UPD out of a generated romwbw_ver.inc
# (tools/build_rom.sh writes it from versions/<ver>/version.json).  The files
# therefore MUST differ, and comparing them byte for byte would fail forever.
#
# So the check that means something is the ARTIFACT, not the source: assembled
# for 3.5.1 - the release romwbw_emu is pinned to - the two must produce the
# same 512 KB ROM.  They do, and that is what proves the parameterisation is
# the ONLY difference.  A stray edit to either copy moves that hash.
#
# Usage: tools/check_source_drift.sh [romwbw_emu-root]
#
#   romwbw_emu-root  defaults to the sibling checkout beside this repository
#
# Exit: 0  the copies agree, or romwbw_emu is not here to compare against
#       1  they have drifted
#
# SKIPS rather than fails when romwbw_emu is absent.  A machine that has this
# repository need not have the other one, and a check that cannot run has not
# found anything - it says so instead of going red.

set -eu
. "$(dirname "$0")/common.sh"

EMU_ROOT="${1:-$ROOT/../romwbw_emu}"
WORKDRIFT="$BUILD/.drift-check"

if [ ! -d "$EMU_ROOT/src" ]; then
    echo "SKIP: no romwbw_emu checkout at $EMU_ROOT"
    echo "      Pass its path to compare: tools/check_source_drift.sh /path/to/romwbw_emu"
    exit 0
fi

rc=0
pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*" >&2; rc=1; }

echo "comparing $ROOT/src against $EMU_ROOT/src"
echo

# --- the three that must match byte for byte -------------------------------

echo "Sources that must be identical:"
for f in r8.asm w8.asm emu_rom.asm; do
    a="$ROOT/src/$f"
    b="$EMU_ROOT/src/$f"
    if [ ! -f "$a" ]; then bad "$f is missing from this repository"; continue; fi
    if [ ! -f "$b" ]; then bad "$f is missing from $EMU_ROOT/src"; continue; fi
    if cmp -s "$a" "$b"; then
        pass "$f"
    else
        bad "$f has drifted - diff $a $b"
    fi
done
echo

# --- the one that must differ, and only in the documented way ---------------
#
# Assert the difference is still the parameterisation and nothing else: this
# copy must take its version from the generated include and must NOT carry a
# hardcoded stamp, and romwbw_emu's must be the other way round.  This is a
# cheap structural check; the hash comparison below is the real one.

echo "emu_hbios.asm, which differs on purpose:"
a="$ROOT/src/emu_hbios.asm"
b="$EMU_ROOT/src/emu_hbios.asm"
if cmp -s "$a" "$b"; then
    bad "emu_hbios.asm is now IDENTICAL to romwbw_emu's - this copy has lost its
        romwbw_ver.inc parameterisation and can no longer build a ROM for any
        release but the one hardcoded in it"
else
    grep -q 'include[[:space:]]*romwbw_ver.inc' "$a" &&
        pass "this copy takes its version from the generated romwbw_ver.inc" ||
        bad "this copy no longer includes romwbw_ver.inc"
    if grep -qE '^\s*(CB_VERSION:)?\s*db\s+0(35|10)h' "$a"; then
        bad "this copy has a hardcoded version stamp again - it must use RMV_VER/RMV_UPD"
    else
        pass "and carries no hardcoded version stamp"
    fi
fi
echo

# --- the check that actually proves it --------------------------------------
#
# Same release, same bytes.  romwbw_emu is cut from 3.5.1, so that is the
# release to compare at; if this repository has not built 3.5.1 there is
# nothing to compare and saying so is the honest result.

echo "Built artifacts, which is where drift would actually show:"
DISKS_ROM="$BUILD/$(release_tag 3.5.1)/$(asset_name emu_avw .rom 3.5.1)"
EMU_ROM="$EMU_ROOT/roms/emu_avw.rom"
if [ ! -f "$DISKS_ROM" ]; then
    echo "  info  $DISKS_ROM not built - run tools/build_all.sh 3.5.1 to compare ROMs"
elif [ ! -f "$EMU_ROM" ]; then
    echo "  info  $EMU_ROM absent - nothing to compare against"
elif cmp -s "$DISKS_ROM" "$EMU_ROM"; then
    pass "emu_avw.rom is byte-identical in both trees"
else
    bad "emu_avw.rom DIFFERS between the trees.  Both are built from
        emu_hbios.asm over the same upstream banks 1-15, so this is the symptom
        the source comparison above is meant to catch:
          $DISKS_ROM
          $EMU_ROM"
fi

# r8/w8 are assembled by each tree with its own um80.  Identical sources are
# not by themselves proof of identical output - a different assembler version
# would show up here and nowhere else.
for f in r8 w8; do
    mine="$BUILD/utils/$f.com"
    if [ ! -f "$mine" ]; then
        echo "  info  $mine not built - run tools/build_utils.sh to compare $f.com"
        continue
    fi
    theirs="$WORKDRIFT/$f.com"
    mkdir -p "$WORKDRIFT"
    if ! ( cd "$ROOT/tools" && cpmcp -f wbw_hd1k_0 "$EMU_ROOT/disks/hd1k_combo.img" \
             "0:$f.com" "$theirs" ) 2>/dev/null; then
        echo "  info  could not read $f.com out of $EMU_ROOT/disks/hd1k_combo.img"
        continue
    fi
    if cmp -s "$mine" "$theirs"; then
        pass "$f.com is byte-identical to the one in romwbw_emu's tracked combo"
    else
        bad "$f.com differs from the one in romwbw_emu's tracked combo - the
        sources may match while the assemblers do not"
    fi
done

rm -rf "$WORKDRIFT"
echo
if [ "$rc" -eq 0 ]; then
    echo "PASS: the two copies agree"
else
    echo "FAIL: see above" >&2
fi
exit "$rc"
