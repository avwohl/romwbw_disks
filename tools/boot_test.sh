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
# WHICH RELEASES AN EMULATOR CAN BOOT
#
# It used to be exactly one.  romwbw_emu had a compile-time RomWBW pin
# (src/romwbw_pin.h) and emu_validate_rom_hcb refused any ROM whose HCB
# disagreed with it, so a given binary could boot one of the RomWBW versions
# this repo publishes and had to refuse the rest.
#
# That is no longer true.  The version a guest sees is read out of the loaded
# ROM at run time, and one binary boots any release in that header's
# ROMWBW_SUPPORTED_RELEASES list.  So this script asks the emulator what it
# can run and holds it to that answer - which means the interesting assertion
# is now "one binary booted every published release", not "it refused all but
# one".
#
# Both banner forms are accepted, so this repo still tests correctly against
# an emulator built before that change:
#
#   RomWBW releases this build can run: 3.5.1, 3.6.0     (runtime version)
#   RomWBW compatibility: v3.5.1 (pinned)                (compile-time pin)
#
# What is asserted, per published RomWBW version:
#
#   If the emulator can run it
#     1. A matching ROM plus disk boots to a CP/M prompt.
#     2. It prints the CBIOS banner for that release and NO version-mismatch
#        warning.
#     3. The emulator itself reports that release, read from the ROM.
#        Runtime-version emulators only - a pinned one never read a release
#        out of a ROM, so it has nothing to report.
#     4. A disk from another release, booted against this ROM, DOES print
#        "*** WARNING: HBIOS/CBIOS Version Mismatch ***".  That warning firing
#        is the pass condition - it is what protects a user from a mixed pair,
#        and it is the ONLY thing left protecting them now that the emulator
#        no longer refuses the ROM.
#     5. R8 and W8 round-trip a file through the guest byte-identically.  That
#        exercises the private 0xE1-0xEA host block, which upstream RomWBW
#        knows nothing about and which no upstream test covers.
#
#   If it cannot
#     6. The ROM is REFUSED by name, rather than loaded into a guest that
#        prints nothing.
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
# The R8/W8 round trip below runs the emulator from a scratch directory, so a
# relative EMU= would stop resolving there.  Absolutise it once, here.
case $EMU in
    /*) ;;
    *)  EMU="$(cd "$(dirname "$EMU")" && pwd)/$(basename "$EMU")" ;;
esac

# Every version this repo publishes.  The mismatch check below needs a disk
# from a DIFFERENT release, and that donor has to be searched for across all of
# them - not just the ones named on the command line, or `boot_test.sh 3.5.1`
# would silently skip the one assertion that protects a user from a mixed pair.
ALL_VERSIONS="$(cd "$ROOT/versions" && ls -d */ 2>/dev/null | tr -d '/' | sort | tr '\n' ' ')"
if [ "$#" -gt 0 ]; then
    VERSIONS="$*"
else
    VERSIONS="$ALL_VERSIONS"
fi

# Which releases can this emulator run?  Ask it rather than assume.  The
# newer banner lists them; the older one names a single compile-time pin.
BANNER="$("$EMU" --version 2>&1)"
RUNS="$(echo "$BANNER" |
        sed -n 's/^RomWBW releases this build can run: \(.*\)/\1/p' |
        head -1 | tr -d ' ' | tr ',' ' ')"
PINNED=no
if [ -z "$RUNS" ]; then
    RUNS="$(echo "$BANNER" |
            sed -n 's/.*RomWBW compatibility: v\([0-9.]*\).*/\1/p' | head -1)"
    PINNED=yes
fi
[ -n "$RUNS" ] || die "cannot tell which RomWBW releases $EMU can run, from:
$BANNER"

can_run() {
    for _r in $RUNS; do [ "$_r" = "$1" ] && return 0; done
    return 1
}

echo "emulator: $EMU"
if [ "$PINNED" = yes ]; then
    echo "compile-time pin: v$RUNS  (an emulator from before the runtime version)"
else
    echo "can run RomWBW:$(printf ' v%s' $RUNS)"
fi
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

# As above, but feeds the guest a command script after it reaches the prompt.
# The extra blank line between commands matters: the CCP is still draining the
# previous command's output when the next line arrives, and without it the
# first character of that line is swallowed.
run_emu_script() {
    _rom="$1"; _disk="$2"; _script="$3"
    printf '\n\n\n%s' "$_script" | timeout 60 "$EMU" --romwbw="$_rom" \
        --disk0="$_disk" --boot=2 --escape=none 2>&1 || true
}

rc=0
booted=""
examined=0
pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*" >&2; rc=1; }

for v in $VERSIONS; do
    tag="$(release_tag "$v")"
    dir="$BUILD/$tag"
    rom="$dir/$(asset_name emu_avw .rom "$v")"
    disk="$dir/$(asset_name hd1k_combo .img "$v")"
    [ -f "$rom" ] && [ -f "$disk" ] || { echo "=== $v: not built, skipping ==="; continue; }

    echo "=== RomWBW v$v ==="
    examined=$((examined + 1))

    if can_run "$v"; then
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

        # Only a runtime-version emulator says which release it loaded; a
        # pinned one cannot, because it never read one.
        if [ "$PINNED" = no ]; then
            echo "$out" | grep -q "^RomWBW v$v " &&
                pass "the emulator reports v$v, read from the ROM" ||
                bad "the emulator did not report v$v after loading a v$v ROM"
        fi

        # A disk from a different release must warn.  Find one anywhere in the
        # published set - see ALL_VERSIONS above.  Say so when there is none,
        # rather than passing silently on an assertion that never ran.
        donor=
        for other in $ALL_VERSIONS; do
            [ "$other" = "$v" ] && continue
            odisk="$BUILD/$(release_tag "$other")/$(asset_name hd1k_cpm22 .img "$other")"
            [ -f "$odisk" ] || continue
            donor="$other"
            out2="$(run_emu "$rom" "$odisk" 2)"
            if echo "$out2" | grep -q "Version Mismatch"; then
                pass "a v$other disk on a v$v ROM warns, as it must"
            else
                bad "a v$other disk on a v$v ROM did NOT warn - the guard is not working"
            fi
            break
        done
        [ -n "$donor" ] ||
            echo "  info  no other release is built, so the mismatch guard was not exercised"

        # R8/W8 round trip, on a scratch copy so the published image is not
        # written to.  The payload names the version so a stale out.txt from
        # the previous iteration cannot pass for this one.
        xfer="$WORK/xfer-$v"
        rm -rf "$xfer"; mkdir -p "$xfer"
        cp "$disk" "$xfer/combo.img"
        printf 'host transfer round trip, RomWBW v%s\n' "$v" > "$xfer/src.txt"
        ( cd "$xfer" && run_emu_script "$rom" combo.img \
            'R8 src.txt

W8 SRC.TXT out.txt
' ) > "$xfer/log" 2>&1
        if [ -f "$xfer/out.txt" ] && cmp -s "$xfer/src.txt" "$xfer/out.txt"; then
            pass "R8/W8 round-trip a file byte-identically"
        else
            bad "R8/W8 round trip failed - see $xfer/log"
        fi

        booted="$booted $v"
    else
        # This emulator cannot load this ROM.  The refusal IS the pass.
        out="$(printf '\n' | timeout 20 "$EMU" --romwbw="$rom" --boot=C 2>&1 || true)"
        if echo "$out" | grep -q "ROM is built for RomWBW v$v"; then
            pass "ROM correctly refused (this emulator does not run v$v)"
            pass "to boot v$v, use an emulator whose ROMWBW_SUPPORTED_RELEASES lists it"
        else
            bad "the emulator did not refuse a v$v ROM it cannot run - emu_validate_rom_hcb is not doing its job"
        fi
    fi
    echo
done

# The point of the whole exercise: how many published releases did ONE binary
# boot?  Two or more is what the runtime version bought, and saying so here is
# what makes a regression to a single-release binary visible.
count=0
for v in $booted; do count=$((count + 1)); done
if [ "$count" -gt 1 ]; then
    echo "One emulator binary booted$(printf ' v%s' $booted) - $count published releases."
elif [ "$count" -eq 1 ]; then
    echo "This binary booted$(printf ' v%s' $booted) only."
fi

# Asserting nothing is not passing.  Every version can legitimately take the
# refusal branch - that is a real run with real assertions - but if the loop
# never examined a single version, `rc` is still 0 and the verdict below would
# read PASS on an empty run.  That is the failure mode this catches: an empty
# versions/, an unbuilt build/, or a bad version argument.
if [ "$examined" -eq 0 ]; then
    echo "FAIL: no version was examined - nothing in $BUILD to test" >&2
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    rm -rf "$WORK"
    echo "PASS: the artifacts behave correctly against $EMU"
else
    echo "FAIL: see above" >&2
    echo "      working files kept in $WORK" >&2
fi
exit "$rc"
