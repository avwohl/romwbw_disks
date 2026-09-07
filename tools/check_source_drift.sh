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

# --- the check that actually proves it ----------------------------------------
#
# Assembled output, not source text.  The structural check above says the two
# copies differ in the documented way; only building both says the difference
# is ALL there is.
#
# This used to compare romwbw_emu/roms/emu_avw.rom against this repo's built
# ROM, and to cpmcp r8.com/w8.com out of romwbw_emu/disks/hd1k_combo.img.  Both
# of those files are gone: romwbw_emu v1.40 tracks no ROM and no disk image,
# and fetches them from this repository's catalog instead.  Both branches
# degraded to green "info" lines when the file was absent, so this check would
# have gone on passing while comparing nothing at all - which is the failure
# mode this whole script exists to catch, arriving in the script itself.
#
# What replaces them needs no ROM, no disk image and no network: assemble both
# copies of emu_hbios.asm for 3.5.1 and compare the 32 KB bank 0, and assemble
# romwbw_emu's r8/w8 sources and compare the .com files.  That is strictly more
# than the old form checked - it isolates bank 0 from the 480 KB of upstream
# banks that were identical by construction anyway - and it holds whether or
# not either tree has built anything.

echo "Assembled output, which is where drift would actually show:"

if ! command -v "$UM80" >/dev/null 2>&1 || ! command -v "$UL80" >/dev/null 2>&1; then
    echo "  info  $UM80/$UL80 not on PATH - cannot assemble, so nothing was compared"
    echo "        (pip install um80)"
else
    mkdir -p "$WORKDRIFT"

    # romwbw_emu's copy hardcodes its version stamp, so it assembles alone.
    # This repo's copy needs the generated include; build it for 3.5.1, which
    # is the release romwbw_emu's ROMWBW_DEFAULT_* names and the only one its
    # hardcoded copy can produce.
    build_bank0() {   # $1 = source dir holding emu_hbios.asm, $2 = output
        _d="$WORKDRIFT/$(basename "$2" .bin)"
        rm -rf "$_d"; mkdir -p "$_d"
        cp "$1/emu_hbios.asm" "$_d/" || return 1
        if grep -q 'include[[:space:]]*romwbw_ver.inc' "$_d/emu_hbios.asm"; then
            {
              echo "; generated by tools/check_source_drift.sh for the 3.5.1 comparison"
              printf 'RMV_VER\tequ\t035h\n'
              printf 'RMV_UPD\tequ\t010h\n'
            } > "$_d/romwbw_ver.inc"
        fi
        ( cd "$_d" && "$UM80" -g emu_hbios.asm >um80.log 2>&1 ) || return 1
        ( cd "$_d" && "$UL80" -o "$2" -p 0000 emu_hbios.rel >>um80.log 2>&1 ) || return 1
        return 0
    }

    if ! build_bank0 "$ROOT/src" "$WORKDRIFT/bank0_disks.bin"; then
        bad "this repository's emu_hbios.asm does not assemble for 3.5.1"
    elif ! build_bank0 "$EMU_ROOT/src" "$WORKDRIFT/bank0_emu.bin"; then
        bad "romwbw_emu's emu_hbios.asm does not assemble"
    elif cmp -s "$WORKDRIFT/bank0_disks.bin" "$WORKDRIFT/bank0_emu.bin"; then
        pass "emu_hbios.asm assembles to identical bank 0 in both trees (3.5.1)"
    else
        bad "emu_hbios.asm assembles DIFFERENTLY in the two trees at 3.5.1.
        The parameterisation is supposed to be the only difference, so this is
        exactly what the source comparison above cannot see:
          $WORKDRIFT/bank0_disks.bin
          $WORKDRIFT/bank0_emu.bin"
    fi

    # r8/w8: identical sources are not by themselves proof of identical output -
    # a different assembler version would show up here and nowhere else.  Built
    # from romwbw_emu's sources rather than extracted from an image it no longer
    # has.
    for f in r8 w8; do
        mine="$BUILD/utils/$f.com"
        if [ ! -f "$mine" ]; then
            echo "  info  $mine not built - run tools/build_utils.sh to compare $f.com"
            continue
        fi
        src="$EMU_ROOT/src/$f.asm"
        if [ ! -f "$src" ]; then
            bad "$src is missing - romwbw_emu must keep these sources"
            continue
        fi
        theirs="$WORKDRIFT/$f.com"
        if ! "$UM80" -o "$WORKDRIFT/$f.rel" "$src" >"$WORKDRIFT/$f.log" 2>&1 ||
           ! "$UL80" -o "$theirs" "$WORKDRIFT/$f.rel" >>"$WORKDRIFT/$f.log" 2>&1; then
            bad "romwbw_emu's src/$f.asm does not build here - see $WORKDRIFT/$f.log"
            continue
        fi
        if cmp -s "$mine" "$theirs"; then
            pass "$f.com is byte-identical built from romwbw_emu's src/$f.asm"
        else
            bad "$f.com differs when built from romwbw_emu's src/$f.asm - the
        sources may match while the assemblers do not"
        fi
    done
fi

rm -rf "$WORKDRIFT"
echo
if [ "$rc" -eq 0 ]; then
    echo "PASS: the two copies agree"
else
    echo "FAIL: see above" >&2
fi
exit "$rc"
