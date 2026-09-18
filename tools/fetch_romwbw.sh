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

TAG="$(vjson "$VER" upstream.tag)"

# Only real RomWBW releases are published from here.  Upstream also tags
# development snapshots - v3.7.0-dev.13 at the time of writing - and they are
# not eligible:
#
#   - a snapshot's HCB carries the same two version bytes as the release it
#     precedes (3.7.0-dev.13 reads 37 00, exactly as a released 3.7.0 would),
#     so no version-byte check can tell them apart
#   - RomWBW's CBIOS compares major.minor only, so a snapshot disk on a release
#     ROM of the same major.minor does NOT print a mismatch warning
#   - upstream may change anything before the release ships, and this repo's
#     per-version tags are immutable once published
#
# The romwbw_emu tree already has one of these mistaken for a build input:
# archive/romwbw-v3.6.0/SBC_simh_std_v360.rom is a v3.6.0-dev.46 snapshot.
#
# The check is a plain string test so it works with no network and no gh, and
# is confirmed against GitHub's own prerelease flag when gh is available.
case "$TAG" in
    v[0-9]*.[0-9]*.[0-9]*)
        case "$TAG" in
            *-*|*+*) not_release=1 ;;
            *)       not_release=0 ;;
        esac ;;
    *) not_release=1 ;;
esac
# A SNAPSHOT IS CARRIED ONLY WHEN THE MANIFEST SAYS SO, IN THE TREE.
# versions/<ver>/version.json may declare "prerelease": true, which is a
# reviewable, per-version, committed decision - not an environment variable
# somebody exported once and forgot. ALLOW_PRERELEASE=1 remains as a local
# escape hatch for a version that has NOT declared itself.
DECLARED_PRE="$("$PYTHON" -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("1" if d.get("prerelease") else "0")' "$ROOT/versions/$VER/version.json")"

if [ "$not_release" = "1" ] && [ "$DECLARED_PRE" != "1" ] && [ "${ALLOW_PRERELEASE:-0}" != "1" ]; then
    die "upstream tag $TAG is not a plain release tag (vX.Y.Z).
       Development snapshots reach a client only when this repository has
       decided to carry one, and that decision is recorded in the manifest:
       set \"prerelease\": true in versions/$VER/version.json.
       Carrying one means accepting that its version bytes are
       indistinguishable from the release it precedes - only the CBIOS banner
       separates them - so it must never be the default, which
       tools/check_committed.py and tools/verify_catalog.py both enforce.
       For a purely local build of something you are NOT carrying, set
       ALLOW_PRERELEASE=1 instead."
fi

# THE SECOND GUARD, which asks GitHub rather than the tag text. It was gh-only,
# and gh needs a token: on a machine whose PAT has expired gh answers 401, the
# ||-fallback made is_pre "unknown", and this check silently did nothing. The
# releases API is public, so curl answers it with no credentials at all.
#
# NORMALISE, because `gh` does not fail quietly. With an expired token it exits
# non-zero AND prints its error body to STDOUT:
#
#     {"message":"Bad credentials","status":"401"}
#
# so the old `gh ... || echo unknown` left is_pre holding that whole blob with
# "unknown" glued to the end - 119 characters matching neither "true", "false"
# nor "unknown". Every comparison below then fell through and the guard did
# nothing, silently, on any machine whose PAT had lapsed. Anything that is not
# exactly "true" or "false" is unknown.
ask_github_prerelease() {
    _ans=""
    if command -v gh >/dev/null 2>&1; then
        _ans="$(gh api "repos/wwarthen/RomWBW/releases/tags/$1" \
                --jq '.prerelease' 2>/dev/null)" || _ans=""
        case "$_ans" in true|false) echo "$_ans"; return ;; esac
    fi
    # The releases API is public, so this needs no credentials and works where
    # gh does not.
    if command -v curl >/dev/null 2>&1; then
        _ans="$(curl -fsS "https://api.github.com/repos/wwarthen/RomWBW/releases/tags/$1" 2>/dev/null |
                "$PYTHON" -c '
import json,sys
try:
    print("true" if json.load(sys.stdin).get("prerelease") else "false")
except Exception:
    print("")' 2>/dev/null)" || _ans=""
        case "$_ans" in true|false) echo "$_ans"; return ;; esac
    fi
    echo unknown
}
is_pre="$(ask_github_prerelease "$TAG")"
case "$is_pre" in
    true)
        if [ "$DECLARED_PRE" != "1" ] && [ "${ALLOW_PRERELEASE:-0}" != "1" ]; then
            die "GitHub marks upstream $TAG as a prerelease, and
       versions/$VER/version.json does not declare \"prerelease\": true.
       Declare it to carry this snapshot, or set ALLOW_PRERELEASE=1 to build
       it locally without carrying it."
        fi ;;
    false)
        # The manifest claims a snapshot that upstream calls a real release.
        # That is a mistake worth catching: the entry would be hidden from every
        # client behind an opt-in it does not need.
        if [ "$DECLARED_PRE" = "1" ]; then
            die "versions/$VER/version.json declares \"prerelease\": true, but
       GitHub marks $TAG as a full release. Remove the flag - a real release
       should not be hidden behind a client's development-snapshot opt-in."
        fi ;;
    *)
        echo "  note  could not reach GitHub to confirm whether $TAG is a" >&2
        echo "        prerelease; going on the tag text and the manifest." >&2 ;;
esac

if [ "$DECLARED_PRE" = "1" ]; then
    echo "NOTE: $TAG is a DEVELOPMENT SNAPSHOT, carried deliberately." >&2
    echo "      Its HCB is indistinguishable from the release it precedes;" >&2
    echo "      the CBIOS banner is the only thing that separates them." >&2
    echo "      It is published non-default and hidden unless a client opts in." >&2
elif [ "${ALLOW_PRERELEASE:-0}" = "1" ]; then
    echo "WARNING: ALLOW_PRERELEASE=1 - building from $TAG, which is not a" >&2
    echo "         RomWBW release, and which this repo does not carry." >&2
    echo "         Do not publish the result." >&2
fi

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
# EXIT 11 IS "one of these patterns matched nothing", NOT a failure to extract.
# Under `set -e` that aborted the script with no message at all, which is the
# worst way to learn that an upstream release reshuffled its Binary directory -
# and a development snapshot is exactly where that happens. Let 11 through and
# let the specific checks below name what is actually missing; anything else is
# a real unzip failure.
unzip -o -q -j "$ZIP" \
    "Binary/SBC_simh_std.rom" "Binary/RCZ80_std.rom" "Binary/hd1k_*.img" \
    -d "$DIR/Binary" || [ "$?" = 11 ] ||
    die "unzip failed on $ZIP"

# Say which of the three the archive did not have, rather than failing later in
# build_rom.sh with a path the reader has to trace back to here.
for want in "$(vjson "$VER" upstream.stock_rom)"; do
    [ -f "$DIR/$want" ] ||
        die "$ZIP has no $want.
       versions/$VER/version.json names it as upstream.stock_rom.
       What the archive does have:
$(ls "$DIR/Binary" 2>/dev/null | sed 's/^/         /' | head -30)"
done
if ! ls "$DIR/Binary"/hd1k_*.img >/dev/null 2>&1; then
    die "$ZIP contained no Binary/hd1k_*.img at all."
fi

echo "PASS: RomWBW v$VER ready at $DIR"
