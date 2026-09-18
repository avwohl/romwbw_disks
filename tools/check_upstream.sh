#!/bin/sh
#
# check_upstream.sh - is there a new RomWBW release worth publishing?
#
# Usage: tools/check_upstream.sh
#
# Answers the question that otherwise gets answered by eyeballing the GitHub
# releases page, which is how a development snapshot gets mistaken for the
# current version.  Upstream tags snapshots like v3.7.0-dev.13 and they sit at
# the top of that page above the newest real release.
#
# A snapshot is publishable from here only when this repository has decided to
# carry that one: its HCB carries the same two version bytes as the release it
# precedes, and RomWBW's CBIOS compares major.minor only, so nothing downstream
# can tell them apart except the CBIOS banner. tools/fetch_romwbw.sh refuses one
# that has not declared itself in versions/<ver>/version.json; this just tells
# you where things stand.

set -eu
. "$(dirname "$0")/common.sh"

# NOT need_tools gh. The releases API is public, and gh needs a token it may not
# have - on an expired PAT it exits non-zero AND prints its 401 body to stdout,
# which is how the same guard in fetch_romwbw.sh silently stopped working.
# curl answers this with no credentials.
list_upstream_releases() {
    if command -v gh >/dev/null 2>&1; then
        if _out="$(gh api repos/wwarthen/RomWBW/releases --paginate \
                   --jq '.[] | "\(.tag_name)\t\(.published_at[0:10])\t\(.prerelease)"' 2>/dev/null)"; then
            case "$_out" in
                *'"message"'*|"") : ;;   # a JSON error body, not the listing
                *) printf '%s\n' "$_out"; return 0 ;;
            esac
        fi
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsS "https://api.github.com/repos/wwarthen/RomWBW/releases?per_page=100" 2>/dev/null |
            "$PYTHON" -c '
import json,sys
try:
    for r in json.load(sys.stdin):
        print("%s\t%s\t%s" % (r["tag_name"], r["published_at"][:10],
                                "true" if r["prerelease"] else "false"))
except Exception:
    sys.exit(1)' && return 0
    fi
    die "could not reach the GitHub releases API, with gh or with curl"
}


have="$(cd "$ROOT/versions" && ls -d */ 2>/dev/null | tr -d '/' | sort)"

echo "Published here:"
for v in $have; do
    printf '  %-16s %s\n' "$v" "$(vjson "$v" status)"
done
echo

# The publication date of the newest release carried here, so older upstream
# releases can be reported as "not carried" rather than as things to chase.
newest_date="$(python3 - "$ROOT/versions" <<'PY'
import json, os, sys
d = sys.argv[1]
dates = []
for v in os.listdir(d):
    f = os.path.join(d, v, "version.json")
    if os.path.isfile(f):
        r = json.load(open(f)).get("released")
        if r:
            dates.append(r)
print(max(dates) if dates else "0000-00-00")
PY
)"

echo "Upstream wwarthen/RomWBW (newest carried here: $newest_date):"
list_upstream_releases |
while IFS="$(printf '\t')" read -r tag date pre; do
    ver="${tag#v}"
    state=""
    for v in $have; do
        if [ "$v" = "$ver" ]; then state="published here"; fi
    done
    if [ -n "$state" ] && [ "$pre" = "true" ]; then
        # Carried on purpose. Ordering matters: this used to test $pre first,
        # so a snapshot this repo had chosen to carry still printed
        # "NOT publishable" - the tool contradicting the tree.
        note="prerelease - CARRIED HERE, non-default"
    elif [ "$pre" = "true" ]; then
        note="prerelease - not carried (declare it to carry it)"
    elif [ -n "$state" ]; then
        note="$state"
    elif [ "$date" \> "$newest_date" ]; then
        # Newer than anything carried here: this is the one to look at.
        note="*** NEWER THAN ANYTHING HERE - CANDIDATE ***"
    else
        note="older, not carried"
    fi
    printf '  %-18s %s  %s\n' "$tag" "$date" "$note"
done
echo
echo "To add a release that is missing, follow the procedure in"
echo "docs/ROMWBW_VERSIONS.md.  Do not add a PRERELEASE."
