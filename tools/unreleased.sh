#!/bin/sh
# unreleased.sh - what is committed here but not yet fetched by anybody?
#
# WHY THIS EXISTS, AND WHY IT MATTERS MORE HERE THAN ANYWHERE ELSE.  Every
# other repository in this family reaches a user through a store or a package
# that somebody has to install.  This one does not: clients compile in one URL
# and read everything else out of documents published here, so a catalog
# published in this repository reaches ALREADY-INSTALLED clients on their next
# fetch, with no release of any app on any platform.  That makes the gap
# between "committed" and "published" the shortest and sharpest in the family -
# it is one asset upload wide, and nothing else has to happen.
#
# THIS IS ONE OF SIX AND THEY ARE DELIBERATELY DIFFERENT.  Every repository
# ships on its own channel, so each unreleased.sh is written for its own rather
# than copied.  check-shipped-disks.sh was "one file in five repos", diverged
# into four that no two of which agreed, and "the check passed" came to mean
# four different things.  This repository never had that script; do not start.
#
#   sh tools/unreleased.sh
#
# HOW THIS RUNS: BY HAND, AND IT MUST STAY THAT WAY.  verify.yml builds and
# tests this repository, which is what CI is for; what a release channel is
# serving is not, and four jobs asking that question across this family were
# deleted on 2026-09-13.  Do not add this to verify.yml.
#
# Exit 0 = it measured, INCLUDING when the answer is "the catalog has moved and
#          has not been published".  Unpublished work is the normal state.
# Exit 2 = could not measure.  Nothing is asserted when nothing was read.
#
# There is no exit 1.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here" && git rev-parse --show-toplevel 2>/dev/null) || {
    echo "CANNOT MEASURE: $here is not inside a git checkout."; exit 2; }

INDEX_URL="https://github.com/avwohl/romwbw_disks/releases/download/catalog-v0/index-v0.json"

get() { # $1 url, $2 dest
    if command -v curl >/dev/null 2>&1; then
        curl -sSfL -m 45 -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qT 45 -O "$2" "$1" 2>/dev/null
    else
        return 127
    fi
}

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t unreleased)
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "romwbw_disks - the catalog every client fetches"
echo

# --- the index, which is the one address clients compile in ------------------
if ! get "$INDEX_URL" "$tmp/pub-index.json"; then
    echo "  CANNOT MEASURE: could not fetch the published index."
    echo "  $INDEX_URL"
    exit 2
fi
committed="$root/catalog/v0/index.json"
if [ ! -f "$committed" ]; then
    echo "  CANNOT MEASURE: no committed index at catalog/v0/index.json."
    exit 2
fi

echo "  index-v0.json"
if cmp -s "$tmp/pub-index.json" "$committed"; then
    echo "    committed and published are byte-identical."
else
    echo "    THEY DIFFER - what is committed has not been published, so no"
    echo "    installed client is seeing it.  Publishing is an asset upload to"
    echo "    the catalog-v0 release; no build of any port is involved."
    command -v diff >/dev/null 2>&1 &&
        diff "$tmp/pub-index.json" "$committed" 2>/dev/null | sed 's/^/      /' | head -30
fi
echo

# --- the per-release catalogs, addressed the way a client addresses them -----
echo "  per-release catalogs"
sed 's/[{,]/\n/g' "$tmp/pub-index.json" |
    sed -n 's/.*"catalog_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    while read -r url; do
        [ -n "$url" ] || continue
        fname=${url##*/}
        rel=${fname#catalog-v0-}
        rel=${rel%.json}
        local_cat="$root/catalog/v0/$rel/catalog.json"
        if [ ! -f "$local_cat" ]; then
            echo "    RomWBW $rel  published, but nothing committed at catalog/v0/$rel/"
            continue
        fi
        if ! get "$url" "$tmp/cat.json"; then
            echo "    RomWBW $rel  could not fetch its published catalog"
            continue
        fi
        if cmp -s "$tmp/cat.json" "$local_cat"; then
            echo "    RomWBW $rel  matches what is published"
        else
            echo "    RomWBW $rel  COMMITTED CATALOG DIFFERS FROM PUBLISHED -"
            echo "                 an image or a hash here is not what clients fetch"
        fi
    done
echo

# --- the help topics, which are a catalog entry like everything else ---------
echo "  help topics"
help_base=$(sed 's/[{,]/\n/g' "$tmp/pub-index.json" |
            sed -n 's/.*"base_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -z "${help_base:-}" ]; then
    echo "    no help base_url in the published index"
else
    for f in "$root"/help/help_*.md; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        if get "$help_base$b" "$tmp/help.md"; then
            if cmp -s "$tmp/help.md" "$f"; then
                echo "    $b  matches"
            else
                echo "    $b  COMMITTED COPY DIFFERS FROM PUBLISHED"
            fi
        else
            echo "    $b  not published at $help_base"
        fi
    done
fi
echo

# --- what has landed here since the catalog was last published ---------------
if command -v gh >/dev/null 2>&1; then
    pub_at=$(gh release view catalog-v0 --repo avwohl/romwbw_disks \
                 --json publishedAt --jq .publishedAt 2>/dev/null)
    if [ -n "${pub_at:-}" ]; then
        touching=$(git -C "$root" rev-list --count --since="$pub_at" HEAD -- catalog/ help/ 2>/dev/null)
        total=$(git -C "$root" rev-list --count --since="$pub_at" HEAD 2>/dev/null)
        echo "  since the catalog-v0 release was published ($pub_at):"
        echo "    ${touching:-0} commit(s) touching catalog/ or help/, of ${total:-0} in total"
        since=$(git -C "$root" log --since="$pub_at" --format='      %h  %ad  %s' \
                    --date=short -- catalog/ help/ 2>/dev/null)
        if [ -n "$since" ]; then
            echo
            echo "$since"
            echo
            echo "    Those are the ones that could change what a client fetches."
            echo "    If the comparisons above all match, they are already out."
        fi
    fi
fi
echo

exit 0
