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
# Anything that is not empty/0/no/false counts as a dry run.  Testing for the
# literal string "1" meant DRY_RUN=true, DRY_RUN=yes and DRY_RUN=on all fell
# through and performed a real, irreversible publish.
case "${DRY_RUN:-0}" in
    ''|0|no|NO|false|FALSE|off|OFF) DRY=0 ;;
    *)                              DRY=1 ;;
esac

# The exact asset list for a version: everything the catalog names, plus the
# catalog itself and the legacy XML.  Publishing is driven by this, never by a
# glob over the build directory - a glob ships whatever happens to be there,
# into a tag that can never be corrected.
catalog_assets() {
    _dir="$1"; _v="$2"
    _cat="$_dir/$(asset_name catalog .json "$_v")"
    [ -f "$_cat" ] || die "no catalog at $_cat"
    python3 - "$_cat" <<'ASSETS'
import json, os, sys
c = json.load(open(sys.argv[1]))
names = [e["filename"] for e in c["roms"]] + [e["filename"] for e in c["disks"]]
base = os.path.basename(sys.argv[1])
names += [base, base.replace("catalog-", "disks-").replace(".json", ".xml")]
print("\n".join(names))
ASSETS
}

run() {
    if [ "$DRY" = "1" ]; then
        echo "    would run: $*"
    else
        "$@"
    fi
}

# Refuse to publish something that has not been checked.  The whole value of
# the catalog is that its hashes are true.
# The per-version tags are immutable and are created at whatever the default
# branch points to, so a dirty tree publishes artifacts whose manifests are not
# in any commit.  build_all.sh itself dirties the tree - fetch records the
# upstream hash, gen_catalog writes catalog/ and versions/*/generation.json -
# so this is the normal state after a build, not an unusual one.
if [ "$DRY" = "0" ]; then
    if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
        die "the working tree is dirty.
       Commit catalog/ and versions/ first: the immutable tag is created at a
       commit, and it must be the commit these artifacts were built from."
    fi
fi
TARGET="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

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
    count=$(find -L "$dir" -type f | wc -l | tr -d ' ')
    bytes=$(find -L "$dir" -type f -exec wc -c {} \; | awk 'BEGIN{s=0} {s+=$1} END{print s}')
    [ "$count" -gt 0 ] || die "$dir holds no files"

    echo "=== $tag  ($count assets, $bytes bytes, status=$status) ==="

    # A per-version tag is immutable in CONTENT, but `gh release create` and
    # `gh release upload` are two commands: an upload that dies partway through
    # 200MB leaves a real release with some of its assets.  Refusing outright
    # made that state unrecoverable, so instead refuse only to CHANGE an asset
    # that is already up, and allow the missing ones to be added.
    # A per-version tag is immutable in CONTENT, but `gh release create` and
    # `gh release upload` are two commands: an upload that dies partway through
    # 200MB leaves a real release carrying only some of its assets.  Refusing
    # outright made that state unrecoverable, so instead:
    #
    #   - an asset already on the release is never re-uploaded and never
    #     clobbered, so published bytes cannot change
    #   - an asset whose size differs from what we would upload is a conflict
    #     and stops the run
    #   - anything missing is uploaded, which completes an interrupted publish
    #
    # Size, not sha256, on purpose: comparing hashes means downloading every
    # asset, and the only thing this has to decide is "finish an interrupted
    # upload" versus "someone is changing an immutable artifact".
    resume=0
    already=""
    if gh release view "$tag" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        sizes="$(gh release view "$tag" --repo "$REPO_SLUG" \
                 --json assets --jq '.assets[] | "\(.name) \(.size)"' 2>/dev/null || true)"
        conflict=""
        for a in $(catalog_assets "$dir" "$v"); do
            remote_size="$(printf '%s\n' "$sizes" | awk -v n="$a" '$1 == n {print $2}')"
            if [ -n "$remote_size" ]; then
                if [ "$remote_size" = "$(filesize "$dir/$a")" ]; then
                    already="$already $a"
                else
                    conflict="$conflict $a"
                fi
            fi
        done
        if [ -n "$conflict" ]; then
            die "$tag already carries a different$conflict
       Per-version tags are immutable.  To correct an artifact, publish a new
       RomWBW version entry or a new interface version - never replace an
       asset in place."
        fi
        echo "  $tag exists; completing it ($(printf '%s' "$already" | wc -w | tr -d ' ') asset(s) already up, left untouched)"
        resume=1
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
        # The catalog being UPLOADED, not the committed copy.  Nothing in the
        # publish path verifies catalog/, so drift between the two would have
        # been published, unchecked, into an immutable release.
        python3 - "$dir/$(asset_name catalog .json "$v")" <<'PY'
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
    if [ "$resume" = "0" ]; then
        run gh release create "$tag" --repo "$REPO_SLUG" \
            --title "RomWBW v$v ($IFACE)" --notes-file "$notes" \
            --latest=false --target "$TARGET" $prerelease
    fi
    # By name, from the catalog, never `"$dir"/*`: a glob ships whatever
    # happens to be in the directory, into a tag that can never be corrected.
    for a in $(catalog_assets "$dir" "$v"); do
        [ -f "$dir/$a" ] || die "$a is named by the catalog but not built"
        skip=0
        for done_a in $already; do
            if [ "$a" = "$done_a" ]; then skip=1; fi
        done
        if [ "$skip" = "1" ]; then
            echo "    already up: $a"
        else
            # No --clobber: an asset that is up stays up, byte for byte.
            run gh release upload "$tag" --repo "$REPO_SLUG" "$dir/$a"
        fi
    done
    echo
done

# The index goes last, so it never advertises a catalog whose assets are not up
# yet.  Delete and recreate rather than upload --clobber: a client may be
# holding a cached copy and the point is that the new one is served promptly.
idxdir="$BUILD/catalog-$IFACE"
if [ -d "$idxdir" ]; then
    echo "=== catalog-$IFACE (index) ==="

    # The index is generated for every BUILT version, not every PUBLISHED one,
    # so publishing a single version could put up a mutable entry point naming
    # a tag that does not exist - a 404 for every client that followed it.
    for rv in $(python3 -c 'import json,sys; print(" ".join(e["romwbw_version"] for e in json.load(open(sys.argv[1]))["romwbw_versions"]))' "$idxdir/index-$IFACE.json"); do
        rtag="$(release_tag "$rv")"
        if [ "$DRY" = "0" ] && ! gh release view "$rtag" --repo "$REPO_SLUG" >/dev/null 2>&1; then
            die "the index names RomWBW $rv but $rtag is not published.
       Publish it first, or regenerate the index without it - the entry point
       must never point at a tag that does not exist."
        fi
    done
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

# The index's `status` is what a client reads; GitHub's prerelease flag is a
# label for a human on the releases page. Two encodings of one fact drift - on
# avwohl/ioscpm four documents ended up describing a --prerelease flag that was
# not set - so rather than trust them to agree, check.
if [ "$DRY" = "0" ]; then
    echo "=== flag check ==="
    for v in $VERSIONS; do
        tag="$(release_tag "$v")"
        want="$(vjson "$v" status)"
        # gh's field is isPrerelease, not prerelease. A wrong name here does not
        # error out into the comparison - it returns empty and every version
        # looks wrong - so it is worth being exact.
        got="$(gh release view "$tag" --repo "$REPO_SLUG" --json isPrerelease --jq '.isPrerelease' 2>/dev/null || echo unknown)"
        case "$want:$got" in
            stable:false|preview:true)
                echo "  ok    $tag  status=$want  prerelease=$got" ;;
            *)
                echo "  FAIL  $tag  the index says status=$want but GitHub says prerelease=$got" >&2
                echo "        The index is authoritative for clients; fix the flag or the status." >&2
                rc_flag=1 ;;
        esac
    done
    [ -z "${rc_flag:-}" ] || die "the published prerelease flags disagree with the catalog status"
    echo
fi

echo "PASS: published"
echo "  https://github.com/$REPO_SLUG/releases/download/catalog-$IFACE/index-$IFACE.json"
