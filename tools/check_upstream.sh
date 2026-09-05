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
# A snapshot is never publishable from here: its HCB carries the same two
# version bytes as the release it precedes, RomWBW's CBIOS compares major.minor
# only, and this repo's per-version tags are immutable once published.
# tools/fetch_romwbw.sh refuses them; this just tells you where things stand.

set -eu
. "$(dirname "$0")/common.sh"

need_tools gh

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
gh api repos/wwarthen/RomWBW/releases --paginate \
   --jq '.[] | "\(.tag_name)\t\(.published_at[0:10])\t\(.prerelease)"' |
while IFS="$(printf '\t')" read -r tag date pre; do
    ver="${tag#v}"
    state=""
    for v in $have; do
        if [ "$v" = "$ver" ]; then state="published here"; fi
    done
    if [ "$pre" = "true" ]; then
        note="prerelease - NOT publishable"
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
