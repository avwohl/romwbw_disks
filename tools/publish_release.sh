#!/bin/sh
#
# publish_release.sh - upload a built tree to GitHub releases.
#
# Usage: tools/publish_release.sh [romwbw-version ...]   (default: all)
#        DRY_RUN=1 tools/publish_release.sh              (print, upload nothing)
#
# Two kinds of tag, and the difference is the whole design:
#
#   v0-romwbw-<ver>   IMMUTABLE.  The ROMs, the disk images, the catalog and
#                     the legacy XML.  Hundreds of megabytes.  Once a client
#                     has shipped against one of these, it can never be
#                     deleted or re-pointed: GitHub release asset URLs cannot
#                     be redirected, so an installed app fetching from it will
#                     keep fetching from it until the app is uninstalled.
#
#   catalog-v0        MUTABLE.  index-v0.json and nothing else, a few KB.
#                     Re-cut whenever a RomWBW version is added or promoted.
#                     It is small on purpose: the floating entry point has to
#                     be cheap to replace, and replacing it must never churn a
#                     51MB image a client has already cached.
#
# Nothing is uploaded that has not passed tools/verify_release.sh.

set -eu
. "$(dirname "$0")/common.sh"

need_tools gh

if [ "$#" -gt 0 ]; then
    VERSIONS="$*"
else
    VERSIONS="$(cd "$ROOT/versions" && ls -d */ 2>/dev/null | tr -d '/' | sort | tr '\n' ' ')"
fi

REPO_SLUG="${REPO_SLUG:-avwohl/romwbw_disks}"
DRY_RUN="${DRY_RUN:-0}"

run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "    would run: $*"
    else
        "$@"
    fi
}

# Refuse to publish something that has not been checked.  The whole value of
# the catalog is that its hashes are true.
echo "Verifying before publish"
sh "$ROOT/tools/verify_release.sh" $VERSIONS >/dev/null ||
    die "verification failed - refusing to publish.  Run tools/verify_release.sh for detail."
echo "  ok"
echo

for v in $VERSIONS; do
    tag="$(release_tag "$v")"
    dir="$BUILD/$tag"
    [ -d "$dir" ] || die "$dir does not exist - run tools/build_all.sh $v"

    status="$(vjson "$v" status)"
    count=$(ls "$dir" | wc -l | tr -d ' ')
    bytes=$(find "$dir" -type f -exec wc -c {} \; | awk '{s+=$1} END {print s}')

    echo "=== $tag  ($count assets, $bytes bytes, status=$status) ==="

    if gh release view "$tag" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        # An existing per-version tag is immutable by contract.  Re-uploading
        # into it would change bytes at a URL a shipped client may already be
        # fetching, which is the one failure mode this layout exists to make
        # impossible.
        die "$tag already exists.  Per-version tags are immutable.
       To correct an artifact, publish a new RomWBW version entry or a new
       interface version - never replace an asset in place."
    fi

    notes="$ROOT/build/.notes-$tag.md"
    {
        echo "Interface \`$IFACE\` artifacts for RomWBW v$v (\`$status\`)."
        echo
        echo "Catalog: \`catalog-$IFACE-$v.json\`  ·  legacy XML: \`disks-$IFACE-$v.xml\`"
        echo
        echo "Do not fetch these by hand-built URL. Start at the index:"
        echo
        echo '```'
        echo "https://github.com/$REPO_SLUG/releases/download/catalog-$IFACE/index-$IFACE.json"
        echo '```'
        echo
        echo "This tag is **immutable**. Its assets will never be replaced."
        echo
        python3 - "$ROOT/catalog/$IFACE/$v/catalog.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("| Asset | Size | sha256 |")
print("|---|---:|---|")
for e in c["roms"] + c["disks"]:
    print("| `%s` | %d | `%s` |" % (e["filename"], e["size"], e["sha256"]))
PY
    } > "$notes"

    prerelease=""
    [ "$status" = "stable" ] || prerelease="--prerelease"

    # --latest=false on every per-version tag.  "Latest" must stay on the index
    # tag: it is the only thing anything should resolve by floating.
    run gh release create "$tag" --repo "$REPO_SLUG" \
        --title "RomWBW v$v ($IFACE)" --notes-file "$notes" \
        --latest=false $prerelease
    run gh release upload "$tag" --repo "$REPO_SLUG" --clobber "$dir"/*
    echo
done

# The index goes last, so it never advertises a catalog whose assets are not up
# yet.  Delete and recreate rather than upload --clobber: a client may be
# holding a cached copy and the point is that the new one is served promptly.
idxdir="$BUILD/catalog-$IFACE"
if [ -d "$idxdir" ]; then
    echo "=== catalog-$IFACE (index) ==="
    if gh release view "catalog-$IFACE" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        :
    else
        run gh release create "catalog-$IFACE" --repo "$REPO_SLUG" \
            --title "Interface $IFACE catalog index" \
            --notes "The entry point for interface \`$IFACE\`. Fetch \`index-$IFACE.json\` from this tag, pick a RomWBW version, then follow its \`catalog_url\`.

This is the only tag in this repo that changes. Every \`$IFACE-romwbw-*\` tag is immutable." \
            --latest
    fi
    run gh release upload "catalog-$IFACE" --repo "$REPO_SLUG" --clobber "$idxdir"/*
    echo
fi

echo "PASS: published"
echo "  https://github.com/$REPO_SLUG/releases/download/catalog-$IFACE/index-$IFACE.json"
