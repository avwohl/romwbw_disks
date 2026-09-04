#!/bin/sh
#
# fetch_romwbw.sh - make an upstream RomWBW release available locally.
#
# Usage: tools/fetch_romwbw.sh <romwbw-version>
#
# Downloads the release Package.zip named in versions/<ver>/version.json and
# extracts only what a build needs (the two stock ROMs and the generic hd1k
# images), because the full archive unpacks to about a gigabyte per release.
#
# The download is recorded in versions/<ver>/version.json under
# upstream.package_sha256 the first time it succeeds; on every later run the
# archive is checked against it.  That is the whole of "pinning" upstream -
# before this repo existed it was a printf telling a human which zip to fetch.

set -eu
. "$(dirname "$0")/common.sh"

VER="${1:?usage: fetch_romwbw.sh <romwbw-version>}"
[ -f "$ROOT/versions/$VER/version.json" ] || die "unknown RomWBW version: $VER"

URL="$(vjson "$VER" upstream.package_url)"
DIR="$ROMWBW_CACHE/$(vjson "$VER" upstream.unpacked_dir)"
ZIP="$DLDIR/RomWBW-v$VER-Package.zip"

mkdir -p "$DLDIR"

# Download to a .part and only promote it once the archive tests clean.  The
# previous version guarded the whole download with [ ! -f "$ZIP" ], so a killed
# run left a truncated zip that was never resumed or re-fetched - and on a
# first fetch, where no hash is recorded yet, the hash OF THE TRUNCATED FILE
# was written into versions/<ver>/version.json as the authoritative pin.
if [ ! -f "$ZIP" ]; then
    echo "Downloading RomWBW v$VER (this is ~200MB)"
    echo "  $URL"
    curl -fL --retry 3 --retry-delay 2 -C - -o "$ZIP.part" "$URL"
    unzip -tqq "$ZIP.part" >/dev/null 2>&1 ||
        die "the archive downloaded for v$VER does not test clean.
       Left at $ZIP.part; delete it and re-run."
    mv "$ZIP.part" "$ZIP"
fi

GOT="$(sha256of "$ZIP")"
WANT="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["upstream"].get("package_sha256",""))' "$ROOT/versions/$VER/version.json")"

if [ -z "$WANT" ]; then
    echo "Recording upstream package hash for v$VER: $GOT"
    python3 - "$ROOT/versions/$VER/version.json" "$GOT" <<'PY'
import json,sys
p,h=sys.argv[1],sys.argv[2]
d=json.load(open(p))
d["upstream"]["package_sha256"]=h
open(p,"w").write(json.dumps(d,indent=2)+"\n")
PY
elif [ "$GOT" != "$WANT" ]; then
    die "RomWBW v$VER Package.zip does not match the recorded hash.
       expected $WANT
       got      $GOT
       Refusing to build from it.  Delete $ZIP to re-download, or update
       upstream.package_sha256 in versions/$VER/version.json on purpose."
fi

mkdir -p "$DIR/Binary"
echo "Extracting build inputs to $DIR/Binary"
unzip -o -q -j "$ZIP" \
    "Binary/SBC_simh_std.rom" "Binary/RCZ80_std.rom" "Binary/hd1k_*.img" \
    -d "$DIR/Binary"

echo "PASS: RomWBW v$VER ready at $DIR"
