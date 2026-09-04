#!/bin/sh
#
# build_all.sh - build every publishable artifact for one or all RomWBW
# releases, then generate the catalogs and verify the result.
#
# Usage: tools/build_all.sh [romwbw-version ...]     (default: all)
#
# This is the whole pipeline.  Running it from a clean checkout on a machine
# with um80, ul80, cpmtools and python3 reproduces the published release byte
# for byte - which is the point of the repo: before it, the ROM and the disk
# images were binaries someone had built once, by hand, and the recipe lived
# partly in prose.

set -eu
. "$(dirname "$0")/common.sh"

if [ "$#" -gt 0 ]; then
    VERSIONS="$*"
else
    VERSIONS="$(cd "$ROOT/versions" && ls -d */ 2>/dev/null | tr -d '/' | sort | tr '\n' ' ')"
fi

echo "=== interface $IFACE, RomWBW: $VERSIONS ==="
echo

# The host-transfer utilities belong to the interface, not to any RomWBW
# release, so they are built once and installed into every version's images.
sh "$ROOT/tools/build_utils.sh"
echo

for v in $VERSIONS; do
    sh "$ROOT/tools/fetch_romwbw.sh" "$v"
    echo
    sh "$ROOT/tools/build_rom.sh" "$v"
    echo
    sh "$ROOT/tools/build_disks.sh" "$v"
    echo
done

python3 "$ROOT/tools/gen_catalog.py" $VERSIONS
echo

sh "$ROOT/tools/verify_release.sh" $VERSIONS
