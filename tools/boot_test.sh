#!/bin/sh
#
# boot_test.sh - actually boot the built artifacts and prove the version story.
#
# Usage: tools/boot_test.sh [romwbw-version ...]     (default: all)
#        EMU=/path/to/romwbw_emu tools/boot_test.sh
#
# Everything else in this repo checks bytes.  This runs them.  It needs the
# romwbw_emu binary, which is not part of this repo, so it SKIPS rather than
# fails when the emulator is absent - a machine that can build the artifacts
# is not necessarily a machine that can run them.
#
# Note what "pass" means per version.  The emulator has a COMPILE-TIME RomWBW
# pin (romwbw_emu/src/romwbw_pin.h), and emu_validate_rom_hcb refuses any ROM
# whose HCB disagrees with it.  So a given emulator binary can only boot ONE
# of the RomWBW versions this repo publishes.  For the others, the correct
# result is the refusal message, and that is what this checks: not "it boots"
# but "it does the right thing".
#
# Four things are asserted:
#
#   1. A matching ROM plus disk boots to a CP/M prompt.
#   2. It prints the CBIOS banner for that release and NO version-mismatch
#      warning.
#   3. A ROM from another release is REFUSED by the emulator, by name.
#   4. A disk from another release, booted against a matching ROM, DOES print
#      "*** WARNING: HBIOS/CBIOS Version Mismatch ***".  That warning firing
#      is the pass condition - it is what protects a user from a mixed pair.
#
# Boot commands are RomWBW's: --boot=2 is the first hard disk (unit 2), slice
# 0.  --boot=0 is not a disk at all.

set -eu
. "$(dirname "$0")/common.sh"

EMU="${EMU:-$ROOT/../romwbw_emu/src/romwbw_emu}"
if [ ! -x "$EMU" ]; then
    echo "SKIP: no romwbw_emu binary at $EMU"
    echo "      Set EMU=/path/to/romwbw_emu to run the boot tests."
    exit 0
fi

if [ "$#" -gt 0 ]; then
    VERSIONS="$*"
else
    VERSIONS="$(cd "$ROOT/versions" && ls -d */ 2>/dev/null | tr -d '/' | sort | tr '\n' ' ')"
fi

# Which release is this emulator pinned to?  Ask it rather than assume.
PIN="$("$EMU" --version 2>&1 | sed -n 's/.*RomWBW compatibility: v\([0-9.]*\).*/\1/p' | head -1)"
[ -n "$PIN" ] || die "cannot read the RomWBW pin from $EMU --version"
echo "emulator: $EMU"
echo "pinned to RomWBW v$PIN"
echo

WORK="$BUILD/.boot-test"
rm -rf "$WORK"; mkdir -p "$WORK"
export XDG_CONFIG_HOME="$WORK/cfg"

# stdin's first line is eaten by the boot loader's AutoBoot prompt, so every
# script fed to the guest starts with blank lines.
run_emu() {
    _rom="$1"; _disk="$2"; _boot="$3"
    printf '\n\n' | timeout 45 "$EMU" --romwbw="$_rom" --disk0="$_disk" \
        --boot="$_boot" --escape=none 2>&1 || true
}

rc=0
pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*" >&2; rc=1; }

for v in $VERSIONS; do
    tag="$(release_tag "$v")"
    dir="$BUILD/$tag"
    rom="$dir/$(asset_name emu_avw .rom "$v")"
    disk="$dir/$(asset_name hd1k_combo .img "$v")"
    [ -f "$rom" ] && [ -f "$disk" ] || { echo "=== $v: not built, skipping ==="; continue; }

    echo "=== RomWBW v$v ==="

    if [ "$v" = "$PIN" ]; then
        out="$(run_emu "$rom" "$disk" 2)"
        echo "$out" | grep -q "CBIOS v$v \[WBW\]" &&
            pass "boots and prints CBIOS v$v [WBW]" ||
            bad "no 'CBIOS v$v [WBW]' banner - did it boot?"
        echo "$out" | grep -q "CP/M-80 v2.2" &&
            pass "reaches the CP/M prompt" ||
            bad "never reached a CP/M prompt"
        echo "$out" | grep -q "Version Mismatch" &&
            bad "printed a version mismatch against its OWN release" ||
            pass "no version-mismatch warning, as expected for a matched pair"

        # A disk from a different release must warn.  Find one.
        for other in $VERSIONS; do
            [ "$other" = "$v" ] && continue
            odisk="$BUILD/$(release_tag "$other")/$(asset_name hd1k_cpm22 .img "$other")"
            [ -f "$odisk" ] || continue
            out2="$(run_emu "$rom" "$odisk" 2)"
            if echo "$out2" | grep -q "Version Mismatch"; then
                pass "a v$other disk on a v$v ROM warns, as it must"
            else
                bad "a v$other disk on a v$v ROM did NOT warn - the guard is not working"
            fi
            break
        done
    else
        # This emulator cannot load this ROM.  The refusal IS the pass.
        out="$(printf '\n' | timeout 20 "$EMU" --romwbw="$rom" --boot=C 2>&1 || true)"
        if echo "$out" | grep -q "ROM is built for RomWBW v$v"; then
            pass "ROM correctly refused by a v$PIN emulator (expected: it is v$v)"
            pass "to boot v$v, build romwbw_emu with that pin, or give it a runtime pin"
        else
            bad "a v$PIN emulator did not refuse a v$v ROM - emu_validate_rom_hcb is not doing its job"
        fi
    fi
    echo
done

rm -rf "$WORK"
if [ "$rc" -eq 0 ]; then
    echo "PASS: the artifacts behave correctly against a v$PIN emulator"
else
    echo "FAIL: see above" >&2
fi
exit "$rc"
