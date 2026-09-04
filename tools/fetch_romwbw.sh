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

if [ ! -f "$ZIP" ]; then
    echo "Downloading RomWBW v$VER (this is ~200MB)"
    echo "  $URL"
    # -C - resumes a partial file; without it a killed run leaves a truncated
    # zip that unzip reports as corrupt rather than as incomplete.
    curl -fL --retry 3 --retry-delay 2 -C - -o "$ZIP" "$URL"
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
