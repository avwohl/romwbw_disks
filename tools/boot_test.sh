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
# EVERY PUBLISHED RELEASE IS TESTED, UNCONDITIONALLY
#
# This went through three shapes.  romwbw_emu once had a compile-time RomWBW
# pin and refused any ROM whose HCB disagreed with it, so a binary booted one
# published release and refused the rest.  Then it carried a compile-time LIST
# (ROMWBW_SUPPORTED_RELEASES), and this script asked the binary which releases
# it allowed - parsing "RomWBW releases this build can run:" off --version -
# and held it to that answer, asserting a refusal for the rest.
#
# romwbw_emu v1.44 deleted the list.  The emulator loads any ROM with a
# readable HBIOS configuration block, so there is nothing to ask and nothing
# that may legitimately be refused.  THIS SCRIPT NO LONGER PARSES --version;
# it tests every version in versions/, and a ROM that does not boot is a
# failure rather than a possible correct refusal.
#
# That matters for publishing: this script is the gate that replaced the
# compile-time list.  Publishing a release into the v0 index is the assertion
# that it passed here (docs/INTERFACE_V0.md), so a refusal branch that turned
# "cannot boot" into a pass would be the one thing that must not exist.
#
# What is asserted, per published RomWBW version:
#
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
#
#        THE LIMIT OF THAT PROTECTION: RomWBW's CBIOS compares major.minor and
#        nothing else.  So it protects a 3.5.x/3.6.x pair and CANNOT protect a
#        development snapshot from the release it precedes - a 3.7.0-dev.14
#        disk on a released-3.7.0 ROM is silent, and no change here could make
#        it speak.  That is why a snapshot is carried non-default and behind a
#        client opt-in; see CLAUDE.md.  The donor below is chosen to differ in
#        major.minor so this assertion tests the guard rather than that limit.
#     5. R8 and W8 round-trip a file through the guest byte-identically.  That
#        exercises the private 0xE1-0xEA host block, which upstream RomWBW
#        knows nothing about and which no upstream test covers.
#
# There is no sixth assertion and no "if it cannot" case.  Until v1.44 the
# emulator carried a compile-time release allowlist and a release it did not
# list was expected to be REFUSED by name - a refusal was a pass.  Nothing may
# be refused now, so a ROM that does not boot is a failure.
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

# Nothing is asked of the binary here.  It used to be interrogated for a
# compile-time release allowlist; there is none, and every published release
# must boot.
echo "emulator: $EMU"
echo "testing RomWBW:$(printf ' v%s' $VERSIONS)"
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

# The same, on a chosen boot target rather than always slice 0.  `2.N` is unit
# 2, slice N - the combo image carries six.
run_emu_script_at() {
    _rom="$1"; _disk="$2"; _boot="$3"; _script="$4"
    printf '\n\n\n\n%s' "$_script" | timeout 60 "$EMU" --romwbw="$_rom" \
        --disk0="$_disk" --boot="$_boot" --escape=none 2>&1 || true
}

# One operating system on one slice: boot it and look for the string only that
# system prints.  Every pattern below was read off a real boot of both published
# releases on 2026-09-18, not guessed from a manual.
boots_as() {
    _rom="$1"; _disk="$2"; _boot="$3"; _label="$4"; _pattern="$5"
    # The pattern is a regex; show it the way it reads on screen.
    _shown="$(printf '%s' "$_pattern" | tr -d '\\')"
    if run_emu "$_rom" "$_disk" "$_boot" | grep -q "$_pattern"; then
        pass "$_label boots (\"$_shown\")"
    else
        bad "$_label did not boot on $_boot - no \"$_shown\""
    fi
}

rc=0
booted=""
examined=0
pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*" >&2; rc=1; }

# EVERY BOOT WRITES TO ITS DISK.  A guest is an operating system: CP/M's SUBMIT
# leaves $$$.SUB behind, NZCOM writes NZCOM.ZCM, and each of the six slices this
# script boots gets scratch files from whatever came up on it.  Booting the
# build tree's own images therefore MUTATES the artifacts this script exists to
# gate - and gen_catalog.py hashes those same files, so a boot test between the
# build and the catalog silently bakes a guest's scratch files into a published
# image.
#
# It was doing exactly that, found 2026-09-18 by rebuilding a combo image from
# stock and finding the build tree's copy differed from the PUBLISHED one by two
# directory entries in slice 2 - "$$$     SUB" at 0x1107CE1 and an NZCOM entry
# at 0x1400000 - where stock and published both hold $E5. Only the R8/W8
# round-trip below was on a scratch copy, and its comment says why; every other
# boot here went straight at $BUILD.
#
# So: copy once per release, boot the copies, and never hand $BUILD to the
# emulator.
boot_copy_dir() {
    _v="$1"
    _src="$BUILD/$(release_tag "$_v")"
    _dst="$WORK/img-$_v"
    if [ ! -d "$_dst" ]; then
        mkdir -p "$_dst"
        # Images only. The ROM is read-only to the emulator, but copying it too
        # keeps one directory per release and costs nothing.
        cp "$_src"/*.img "$_src"/*.rom "$_dst"/ 2>/dev/null || true
    fi
    echo "$_dst"
}

for v in $VERSIONS; do
    tag="$(release_tag "$v")"
    srcdir="$BUILD/$tag"
    # Presence is asked of the BUILD tree, so "not built" still means not built.
    [ -f "$srcdir/$(asset_name emu_avw .rom "$v")" ] &&
    [ -f "$srcdir/$(asset_name hd1k_combo .img "$v")" ] ||
        { echo "=== $v: not built, skipping ==="; continue; }
    dir="$(boot_copy_dir "$v")"
    rom="$dir/$(asset_name emu_avw .rom "$v")"
    disk="$dir/$(asset_name hd1k_combo .img "$v")"

    echo "=== RomWBW v$v ==="
    examined=$((examined + 1))
    rc_before="$rc"

    out="$(run_emu "$rom" "$disk" 2)"
    {
        echo "$out" | grep -q "CBIOS v$v \[WBW\]" &&
            pass "boots and prints CBIOS v$v [WBW]" ||
            bad "no 'CBIOS v$v [WBW]' banner - did it boot?"
        echo "$out" | grep -q "CP/M-80 v2.2" &&
            pass "reaches the CP/M prompt" ||
            bad "never reached a CP/M prompt"
        echo "$out" | grep -q "Version Mismatch" &&
            bad "printed a version mismatch against its OWN release" ||
            pass "no version-mismatch warning, as expected for a matched pair"

        # THE ROM CANNOT SAY WHICH SNAPSHOT IT IS, AND THE DISK CAN.  This is
        # the whole reason a development snapshot is dangerous to carry, and
        # this is where it shows, so assert it rather than paper over it.
        #
        # The emulator reports the version it reads out of the HCB, which holds
        # exactly two bytes - a version and an update byte. v3.7.0-dev.14 reads
        # 57 a8 37 00, which is byte for byte what a released 3.7.0 will read,
        # so the emulator says "RomWBW v3.7.0" for both and no check on those
        # bytes could ever separate them.
        #
        # The CBIOS banner in the disk image is a STRING, and it does carry the
        # suffix: "CBIOS v3.7.0-dev.14 [WBW]", asserted above. So for a
        # snapshot the pair is deliberately asymmetric - ROM says 3.7.0, disk
        # says 3.7.0-dev.14 - and that asymmetry is the only thing in the
        # system that can tell a snapshot from its release.
        core="${v%%-*}"
        echo "$out" | grep -q "^RomWBW v$core " &&
            pass "the emulator reports v$core, read from the ROM's HCB" ||
            bad "the emulator did not report v$core after loading a v$v ROM"
        if [ "$core" != "$v" ]; then
            # Belt and braces: if a future upstream ever put the suffix in the
            # HCB, this assertion is how we would find out, because the line
            # above would still pass and this one would start failing.
            echo "$out" | grep -q "^RomWBW v$v " &&
                bad "the ROM reported the full tag v$v - the HCB has gained a
      suffix it could not carry before, and the snapshot/release ambiguity
      this repo documents may no longer hold. Re-read fetch_romwbw.sh." ||
                pass "and cannot report the -${v#*-} suffix, which only the disk banner carries"
        fi

        # A disk from a different release must warn.  Find one anywhere in the
        # published set - see ALL_VERSIONS above.  Say so when there is none,
        # rather than passing silently on an assertion that never ran.
        #
        # THE DONOR MUST DIFFER IN MAJOR.MINOR, and that is not the same as
        # "is a different version".  RomWBW's CBIOS compares major.minor ONLY,
        # so a 3.7.0-dev.14 disk against a released-3.7.0 ROM is silent - and
        # correctly so, because CBIOS cannot see the difference.  Picking such
        # a pair as the donor would make this assertion fail and report a
        # working guard as a broken one.  Today the donor happens to be 3.5.1
        # and the question does not arise; it arises the day a real 3.7.0 lands
        # beside the snapshot, which is exactly when someone would be reading
        # this output for reassurance.
        mm() { echo "$(vjson "$1" hbios.major).$(vjson "$1" hbios.minor)"; }
        my_mm="$(mm "$v")"
        donor=
        for other in $ALL_VERSIONS; do
            [ "$other" = "$v" ] && continue
            [ "$(mm "$other")" = "$my_mm" ] && continue
            [ -f "$BUILD/$(release_tag "$other")/$(asset_name hd1k_cpm22 .img "$other")" ] || continue
            odisk="$(boot_copy_dir "$other")/$(asset_name hd1k_cpm22 .img "$other")"
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

        # THE OTHER FIVE OPERATING SYSTEMS.
        #
        # Everything above this exercises the CP/M 2.2 path and nothing else.
        # The other five were booted by hand once, on 2026-09-05, and by no
        # script until 2026-09-18 - so for thirteen days of commits, including
        # a ROM rebuild that moved every published sha256, "RomWBW 3.6.0 boots
        # six operating systems" rested on what one person saw once.  These run
        # every time now.
        #
        # Four are slices of the combo image (0 CP/M 2.2, 1 ZSDOS, 2 NZCOM,
        # 3 CP/M 3, 4 ZPM3, 5 word processing); Z3PLUS has an image of its own.
        # Each pattern is what that system prints and the others do not.
        boots_as "$rom" "$disk" 2.1 "ZSDOS"  "ZSDOS v1.1"
        boots_as "$rom" "$disk" 2.4 "ZPM3"   "ZCPR compatible system for CP/M+"

        # CP/M 3's banner names the HBIOS release it is running under, so this
        # one assertion covers the banked path AND the pairing.  It is the only
        # guest banner in the set that moves with the release.
        # CP/M 3's banner names the HBIOS release, so this assertion covers the
        # ROM/disk pairing too. It carries the FULL tag on a snapshot - measured
        # 2026-09-18 on the built image: "for HBIOS v3.7.0-dev.14", not
        # "v3.7.0" - so BIOS3.SPR is a second string-valued witness beside the
        # CBIOS banner, and neither is the two-byte HCB.
        boots_as "$rom" "$disk" 2.3 "banked CP/M 3" \
            "CP/M v3.0 \[BANKED\] for HBIOS v$v"

        # NZCOM is the awkward one.  The slice's volume LABEL differs between
        # releases - "NZ-COM" under 3.6.0, "ZSDOS 1.1" under 3.5.1 - so a label
        # is not the test.  What is: after NZCOM.ZCM loads, the ZCPR3 command
        # processor is resident, and it answers an unknown command differently
        # from the stock CP/M CCP.  `PATH` gets "No File" here and "PATH?" on
        # slice 0, on both releases.  That is Z-System being present, not a
        # string that happens to be in the boot text.
        nz="$(run_emu_script_at "$rom" "$disk" 2.2 'PATH
')"
        case "$nz" in
            *"NZCOM NZCOM.ZCM"*) : ;;
            *) bad "NZCOM slice did not run its NZCOM.ZCM autoexec" ;;
        esac
        case "$nz" in
            *"No File"*)
                pass "NZCOM boots and ZCPR3 is resident (PATH -> \"No File\")" ;;
            *"PATH?"*)
                bad "NZCOM slice booted to a stock CP/M CCP - PATH answered \"PATH?\", so NZCOM did not take" ;;
            *)
                bad "NZCOM slice: PATH answered neither \"No File\" nor \"PATH?\"" ;;
        esac

        # Z3PLUS ships as its own image rather than a combo slice.  It is built
        # by the same run of build_all.sh, so a missing file is a broken build
        # and not an excuse to skip - this file has no skip that reads as a pass.
        z3="$dir/$(asset_name hd1k_z3plus .img "$v")"
        if [ -f "$z3" ]; then
            boots_as "$rom" "$z3" 2 "Z3PLUS" "The Z-System for CP/M PLUS"
        else
            bad "$(basename "$z3") is not built, so Z3PLUS was not booted"
        fi

        # THE NVRAM SEED.  RomWBW's NVSW_CHECKSUM XORs the two version bytes
        # into its seed, so a blob written under one release fails validation
        # under another and the loader silently reverts to defaults.  "NV
        # Switches Found" is the loader saying the stored block validated
        # against the ROM it just read - which is the whole of what that check
        # was, done by hand, in 2026-09-05's notes.  It is already in $out, so
        # it costs no extra boot.
        echo "$out" | grep -q "NV Switches Found" &&
            pass "the boot loader validated NVRAM against this ROM (NV Switches Found)" ||
            bad "no 'NV Switches Found' - the NVRAM checksum seed disagrees with the ROM"

        # Only count it as booted if every assertion above held.  The
        # summary line below is the headline result, and a version whose
        # CBIOS banner and mismatch checks both failed must not appear in it.
        [ "$rc" -eq "$rc_before" ] && booted="$booted $v"
    }
    echo
done

# The point of the whole exercise: how many published releases did ONE binary
# boot?  Every one of them, now that there is no allowlist - saying so here is
# what makes a regression to a single-release binary visible.
count=0
for v in $booted; do count=$((count + 1)); done
if [ "$count" -gt 1 ]; then
    echo "One emulator binary booted$(printf ' v%s' $booted) - $count published releases."
elif [ "$count" -eq 1 ]; then
    echo "This binary booted$(printf ' v%s' $booted) only."
fi

# Asserting nothing is not passing.  If the loop never examined a single
# version, `rc` is still 0 and the verdict below would read PASS on an empty
# run.  That is the failure mode this catches: an empty versions/, an unbuilt
# build/, or a bad version argument.
#
# This used to add "every version can legitimately take the refusal branch -
# that is a real run with real assertions".  There is no refusal branch any
# more: nothing may be refused, so a version that does not boot is a failure
# and never a quiet pass.
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
