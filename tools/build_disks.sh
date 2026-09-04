#!/bin/sh
#
# build_disks.sh - assemble the publishable disk set for one RomWBW release.
#
# Usage: tools/build_disks.sh <romwbw-version>
# Output: build/<iface>-romwbw-<ver>/<disk-id>-<iface>-<ver>.img
#
# Each image starts as the stock one from that release's Package.zip.  The only
# thing this repo adds is W8.COM and R8.COM - the host file transfer pair - and
# only on the images versions/<ver>/disks.json says to add them to.  Everything
# else ships exactly as upstream built it, which is what makes "this disk is
# RomWBW v3.6.0" a true statement rather than a label.
#
# Every image is checked for its CBIOS banner afterwards.  A bootable image
# whose banner names a different release is the exact condition that makes the
# guest print "*** WARNING: HBIOS/CBIOS Version Mismatch ***" at boot, and it
# is far cheaper to catch here than in a user's terminal.

set -eu
. "$(dirname "$0")/common.sh"

VER="${1:?usage: build_disks.sh <romwbw-version>}"
[ -f "$ROOT/versions/$VER/disks.json" ] || die "unknown RomWBW version: $VER"
need_tools cpmcp cpmrm cpmls

TAG="$(release_tag "$VER")"
OUT="$BUILD/$TAG"
SRCDIR="$ROMWBW_CACHE/$(vjson "$VER" upstream.unpacked_dir)"
UTILS="$BUILD/utils"
DISKJSON="$ROOT/versions/$VER/disks.json"

[ -f "$UTILS/w8.com" ] || die "build/utils/w8.com missing - run tools/build_utils.sh first"

# cpmtools reads ./diskdefs if there is one and the system file otherwise, and
# no distribution's system file carries the combo slice definitions.  So every
# cpmtools call runs from tools/, which is where ours lives.  Image paths are
# absolute, leaving the working directory free for this.
cpmtool() { ( cd "$ROOT/tools" && "$@" ); }

mkdir -p "$OUT"
echo "Building RomWBW v$VER disk images"

# One line per disk: id, upstream path, diskdef, and the slices to inject into.
python3 - "$DISKJSON" > "$BUILD/.disks-$VER.tsv" <<'PY'
import json,sys
for d in json.load(open(sys.argv[1]))["disks"]:
    print("\t".join([d["id"], d["upstream"], d["diskdef"],
                     ",".join(d.get("inject_utils", [])) or "-"]))
PY

built=0; injected=0; fail=0
: > "$BUILD/.diskinfo-$VER.tsv"

while IFS='	' read -r id upstream def slices; do
    src="$SRCDIR/$upstream"
    if [ ! -f "$src" ]; then
        echo "FAIL  $id: upstream image missing: $src" >&2
        echo "      Run: tools/fetch_romwbw.sh $VER" >&2
        fail=$((fail + 1)); continue
    fi

    img="$OUT/$(asset_name "$id" .img "$VER")"
    cp "$src" "$img"
    chmod u+w "$img"

    # A wrong diskdef does not fail loudly - cpmtools reads a garbage directory
    # and cpmcp writes at the wrong offset while reporting success - so the
    # shape is checked against the def before anything is written.
    size="$(filesize "$img")"
    case "$def" in
        wbw_hd1k)
            [ "$size" -eq 8388608 ] || { echo "FAIL  $id: $size bytes is not a plain 8MB hd1k slice" >&2; fail=$((fail+1)); rm -f "$img"; continue; } ;;
        wbw_hd1k_*)
            { [ "$size" -gt 1048576 ] && [ $(( (size - 1048576) % 8388608 )) -eq 0 ]; } ||
                { echo "FAIL  $id: $size bytes is not a 1MB prefix plus whole 8MB slices" >&2; fail=$((fail+1)); rm -f "$img"; continue; } ;;
    esac

    got=""
    if [ "$slices" != "-" ]; then
        for sl in $(echo "$slices" | tr ',' ' '); do
            for util in w8 r8; do
                # cpmcp refuses to overwrite, so any existing copy goes first.
                if cpmtool cpmls -f "$sl" "$img" 2>/dev/null | grep -qi "^$util\.com$"; then
                    cpmtool cpmrm -f "$sl" "$img" "0:$util.com" 2>/dev/null || true
                fi
                if ! cpmtool cpmcp -f "$sl" "$img" "$UTILS/$util.com" "0:$util.com" 2>/dev/null; then
                    echo "FAIL  $id: could not install $util.com on slice $sl" >&2
                    fail=$((fail + 1)); continue
                fi
                # cpmrm exits 0 having removed nothing on an image it cannot
                # write, and cpmcp is then the one that complains.  Ask the
                # directory, not the exit code.
                cpmtool cpmls -f "$sl" "$img" 2>/dev/null | grep -qi "^$util\.com$" ||
                    { echo "FAIL  $id: $util.com is not on slice $sl after cpmcp" >&2; fail=$((fail+1)); continue; }
                injected=$((injected + 1))
            done
            got="$got $sl"
        done
    fi

    # One helper answers every question about a built image, so the catalog
    # can never claim something the builder did not measure.  The slice it is
    # asked about is the one w8/r8 went onto, or slice 0 for an image that
    # takes none.
    probe_def="$def"
    if [ "$slices" != "-" ]; then probe_def="${slices%%,*}"; fi
    info="$(python3 "$ROOT/tools/diskinfo.py" "$img" "$probe_def")" ||
        die "$id: diskinfo failed on $img"

    eval "$(printf '%s' "$info" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("bootable=%s" % str(d["bootable"]).lower())
print("cbios=%s" % json.dumps(d["cbios"] or "-"))
print("cbios_all=%s" % json.dumps(" ".join(d["cbios_all"])))
print("got_utils=%s" % json.dumps(",".join(d["utils"]) or "-"))
')"

    # A bootable slice whose CBIOS names a different RomWBW release is exactly
    # the condition that makes the guest print
    #   *** WARNING: HBIOS/CBIOS Version Mismatch ***
    # at boot.  Upstream compares major.minor only, so 3.5.x against 3.6.x
    # always warns while 3.5.0 against 3.5.1 never does - which is why the
    # whole banner is matched here rather than just the first two numbers.
    # A "-dev.NN" banner fails this too: a dev snapshot has the same HCB bytes
    # as its release, so the banner is the only thing that can tell them apart.
    if [ -n "$cbios_all" ] && [ "$cbios_all" != "CBIOS v$VER [WBW]" ]; then
        echo "FAIL  $id: CBIOS banner is not exactly 'CBIOS v$VER [WBW]': $cbios_all" >&2
        echo "      That image would print 'HBIOS/CBIOS Version Mismatch' at boot." >&2
        fail=$((fail + 1)); rm -f "$img"; continue
    fi

    # The utilities the manifest asked for must actually be in the directory.
    if [ "$slices" != "-" ] && [ "$got_utils" != "w8.com,r8.com" ]; then
        echo "FAIL  $id: expected w8.com and r8.com on ${slices%%,*}, found: $got_utils" >&2
        fail=$((fail + 1)); rm -f "$img"; continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(basename "$img")" "$bootable" \
        "$(echo "$got" | sed 's/^ //;s/ /,/g' | sed 's/^$/-/')" "$cbios" \
        >> "$BUILD/.diskinfo-$VER.tsv"
    printf '  %-32s %10s  %-10s %-19s%s\n' "$(basename "$img")" "$size" \
        "$([ "$bootable" = true ] && echo bootable || echo data-only)" \
        "$([ "$cbios" = "-" ] && echo "no CBIOS banner" || echo "$cbios")" \
        "$([ "$slices" != "-" ] && echo " +w8/r8" || echo "")"
    built=$((built + 1))
done < "$BUILD/.disks-$VER.tsv"

rm -f "$BUILD/.disks-$VER.tsv"
[ "$fail" -eq 0 ] || die "$fail disk(s) failed"
echo "PASS: $built image(s), $injected utility cop(y|ies) installed, in $OUT"
