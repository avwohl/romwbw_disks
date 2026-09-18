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

# ONE RULE, used both to create a release and to check the flag afterwards.
# "stable" is the only status that is not a GitHub prerelease; every other
# value - "preview", "snapshot", and whatever comes next - is. Keeping this in
# a function is the point: the creating and the checking sides drifted apart
# once already, and the drift only surfaced after the upload.
gh_prerelease_flag() {
    case "$1" in
        stable) echo false ;;
        *)      echo true ;;
    esac
}

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
#
# UNTRACKED FILES COUNT.  `git diff` reports changes to files git already
# knows about and says nothing about new ones, so this guard was blind in
# exactly the case it matters most: a BRAND-NEW version. Publishing
# v3.7.0-dev.14 would have created an immutable tag at a commit that contained
# no versions/3.7.0-dev.14/ and no catalog/v0/3.7.0-dev.14/ at all - the
# manifests the assets were built from existing nowhere in history - and the
# guard would have said the tree was clean. For 3.5.1 and 3.6.0 every file was
# already tracked, so any change showed as modified and the guard fired; the
# hole opens only on a first publish, which is the one that cannot be redone.
#
# `git status --porcelain` covers modified, staged AND untracked in one test.
if [ "$DRY" = "0" ]; then
    dirt="$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)"
    if [ -n "$dirt" ]; then
        die "the working tree is dirty or has untracked files.
       Commit catalog/ and versions/ first: the immutable tag is created at a
       commit, and it must be the commit these artifacts were built from.

$(printf '%s\n' "$dirt" | sed 's/^/         /' | head -40)"
    fi
fi
TARGET="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

echo "Verifying before publish"
sh "$ROOT/tools/verify_release.sh" $VERSIONS >/dev/null ||
    die "verification failed - refusing to publish.  Run tools/verify_release.sh for detail."
echo "  ok"
echo

# THE GATE.  verify_release.sh checks bytes; boot_test.sh runs them, and
# docs/INTERFACE_V0.md says publishing a release into index-v0.json IS the
# assertion that it passed here.  That assertion was discipline until 2026-09-18:
# nothing ran the script - not build_all.sh, not this one, not verify.yml - while
# three documents said publishing asserted it.
#
# boot_test.sh exits 0 on three paths that are not passes, and a real publish
# refuses all three.  Two are obvious: "SKIP:" when no emulator is present, and
# "not built, skipping" for a version with no artifacts in build/.  The third is
# the one that matters most - "the mismatch guard was not exercised", printed when
# only one release is built, because the guard needs a disk from another release
# to try.  That is assertion 4, and boot_test.sh's own header calls it "the ONLY
# thing left protecting them now that the emulator no longer refuses the ROM".
# All three are right for a build machine and wrong for the thing that asserts the
# release boots: a skip that reads as a pass is the one branch its own header says
# must not exist.  DRY_RUN=1 refuses none of them, because it publishes nothing.
if [ "$DRY" = "0" ]; then
    echo "Boot test before publish"
    boot_out="$(sh "$ROOT/tools/boot_test.sh" $VERSIONS 2>&1)" || {
        printf '%s\n' "$boot_out" | sed 's/^/    /' >&2
        die "the boot test failed - refusing to publish."
    }
    printf '%s\n' "$boot_out" | sed 's/^/    /'
    case "$boot_out" in
        *"SKIP:"*)
            die "the boot test SKIPPED, and publishing asserts it passed.
       Build romwbw_emu beside this repo, or point EMU at its binary:
         EMU=/path/to/romwbw_emu tools/publish_release.sh $VERSIONS
       DRY_RUN=1 does not need it." ;;
        *"not built, skipping"*)
            die "the boot test skipped a version for want of artifacts in $BUILD.
       Nothing may be published on a boot test that did not run it:
         tools/build_all.sh $VERSIONS" ;;
        *"mismatch guard was not exercised"*)
            die "the boot test could not try a disk from another release, so the
       HBIOS/CBIOS mismatch warning - the only thing protecting a user from a
       mixed pair - was never exercised.  It needs ONE other release's
       hd1k_cpm22 image in $BUILD, not all of them:
         tools/build_all.sh <any-other-version>" ;;
    esac
    echo "  ok"
    echo
fi

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
    # 200MB leaves a real release carrying only some of its assets.  Refusing
    # outright made that state unrecoverable, so instead:
    #
    #   - an asset already on the release is never re-uploaded and never
    #     clobbered, so published bytes cannot change
    #   - an asset whose CONTENT differs from what we would upload is a
    #     conflict and stops the run
    #   - anything missing is uploaded, which completes an interrupted publish
    #
    # The comparison is sha256, read off GitHub's own `digest` field, and it
    # downloads nothing: the release metadata carries it.  It used to be size,
    # which cannot tell "finish an interrupted upload" from "someone rebuilt
    # bank 0" - every ROM is 512 KB before and after, and a catalog whose
    # hashes changed is the same length to the byte, because a sha256 is a
    # fixed-width field.  So a respin printed "already up" for every asset and
    # exited PASS having changed nothing.  An asset GitHub reports no digest for
    # falls back to size, and says so rather than pretending to have checked.
    resume=0
    already=""
    if gh release view "$tag" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        remote="$(gh release view "$tag" --repo "$REPO_SLUG" \
                 --json assets --jq '.assets[] | "\(.name) \(.size) \(.digest // "-")"' 2>/dev/null || true)"
        conflict=""
        for a in $(catalog_assets "$dir" "$v"); do
            remote_size="$(printf '%s\n' "$remote" | awk -v n="$a" '$1 == n {print $2}')"
            [ -n "$remote_size" ] || continue      # not up yet; uploaded below
            remote_digest="$(printf '%s\n' "$remote" | awk -v n="$a" '$1 == n {print $3}')"
            if [ "$remote_digest" = "-" ]; then
                note "$a: GitHub reports no digest, comparing size only"
                if [ "$remote_size" = "$(filesize "$dir/$a")" ]; then
                    already="$already $a"
                else
                    conflict="$conflict $a"
                fi
            elif [ "$remote_digest" = "sha256:$(sha256of "$dir/$a")" ]; then
                already="$already $a"
            else
                conflict="$conflict $a"
            fi
        done
        if [ -n "$conflict" ]; then
            die "$tag already carries different bytes for:$conflict
       Per-version tags are immutable.  To correct an artifact, publish a new
       RomWBW version entry or a new interface version - never replace an
       asset in place.  If you rebuilt these on purpose, this script is not
       the way to publish them: see docs/RELEASING.md section 5."
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
        # latest/download, not the tag: that is the one string every client
        # compiles in, and it is what lets the index move with no client
        # release.  See the header of tools/gen_catalog.py.  The tag-named URL
        # stays served for clients built before 29635dd, but nothing new should
        # be told to use it.
        echo "https://github.com/$REPO_SLUG/releases/latest/download/index-$IFACE.json"
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

    # An `a && b` list under `set -e` aborts the script when a is false, which
    # for a "stable" release is every time. This is an if, not a one-liner -
    # the same trap build_disks.sh already carries a comment about.
    prerelease=""
    if [ "$(gh_prerelease_flag "$status")" = "true" ]; then
        prerelease="--prerelease"
    fi

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

    # READ THE WHOLE TAG BACK, against the files on disk.  Never trust an upload
    # that was not read back: on 2026-09-10 an upload of index-v0.json reported
    # success, moved the asset's updated_at, and went on serving the old bytes.
    # This is that check for a per-version tag, and it is one API call - GitHub
    # reports a `digest` per asset, so nothing is downloaded.  It compares against
    # the local file rather than against the catalog on purpose: verify_release.sh
    # has already proved the local files are what the catalog claims, so served ==
    # local closes the chain, and it covers the catalog and the legacy XML too,
    # neither of which carries a hash anybody could look up.
    #
    # It matters here more than anywhere: the tag is immutable, so an asset stored
    # wrong can never be corrected, and the index that would advertise it has not
    # gone up yet.  This is the last moment anything can be done about it.
    if [ "$DRY" = "0" ]; then
        served="$BUILD/.served-$tag"
        gh release view "$tag" --repo "$REPO_SLUG" --json assets \
           --jq '.assets[] | "\(.name) \(.size) \(.digest // "-")"' > "$served" ||
            die "$tag was published but its asset list could not be read back."
        rb_bad=""
        rb_n=0
        rb_sizeonly=0
        for a in $(catalog_assets "$dir" "$v"); do
            rb_n=$((rb_n + 1))
            want_size="$(filesize "$dir/$a")"
            srv_size="$(awk -v n="$a" '$1 == n {print $2}' "$served")"
            srv_dg="$(awk -v n="$a" '$1 == n {print $3}' "$served")"
            if [ -z "$srv_size" ]; then
                rb_bad="$rb_bad
       $a is named by the catalog and is not on the release at all"
            elif [ "$srv_dg" = "-" ]; then
                if [ "$srv_size" = "$want_size" ]; then
                    note "$a: no digest served, size only"
                    rb_sizeonly=$((rb_sizeonly + 1))
                else
                    rb_bad="$rb_bad
       $a is served at $srv_size bytes, not $want_size (and no digest to compare)"
                fi
            elif [ "$srv_dg" != "sha256:$(sha256of "$dir/$a")" ]; then
                rb_bad="$rb_bad
       $a is served at $srv_dg, not sha256:$(sha256of "$dir/$a")"
            fi
        done
        if [ -n "$rb_bad" ]; then
            die "$tag does not serve what was uploaded:$rb_bad
       The tag is immutable, so this cannot be corrected in place - and the index
       has not gone up, which is the only good news.  A client would verify every
       one of these and reject it.  Delete the release, rebuild, cut it again."
        fi
        if [ "$rb_sizeonly" = "0" ]; then
            note "read back: all $rb_n asset(s) on $tag serve the bytes on disk"
        else
            note "read back: $rb_n asset(s) on $tag, of which $rb_sizeonly matched on SIZE ONLY (GitHub served no digest for them)"
        fi
        rm -f "$served"
    fi
    echo
done

# The index goes last, so it never advertises a catalog whose assets are not up
# yet.
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
    # NEVER `--clobber`, and never a glob.  Both halves of that were learned on
    # 2026-09-10 in one command.  A glob uploads an asset named for the LOCAL
    # file, so `catalog/v0/index.json` created a second asset beside the real
    # `index-v0.json` and left the published entry point untouched.  Then a
    # `--clobber` of the right name printed nothing, moved the asset's
    # updated_at, and STILL served the old document - both versions were 5421
    # bytes, which is the condition that hides it.  What worked was
    # `gh release delete-asset` followed by a plain upload of a file whose name
    # ON DISK is already the published asset name.
    idxasset="index-$IFACE.json"
    [ -f "$idxdir/$idxasset" ] ||
        die "no $idxasset in $idxdir - run tools/gen_catalog.py --index"
    # -F: the name is a literal, not a basic regular expression.  Unanchored
    # `index-v0.json` would also match `index-v0xjson`, which is a small thing,
    # but this is the one asset in the repository whose identity decides whether
    # every installed client can find anything at all.
    if gh release view "catalog-$IFACE" --repo "$REPO_SLUG" \
         --json assets --jq '.assets[].name' 2>/dev/null | grep -Fqx "$idxasset"; then
        run gh release delete-asset "catalog-$IFACE" "$idxasset" \
            --repo "$REPO_SLUG" --yes ||
            die "could not delete the old $idxasset from catalog-$IFACE.  It is
       still serving the previous index, which is the safe end of this failure:
       nothing has changed.  Fix the access problem and run this again."
    fi
    # If the delete succeeded and this fails, `releases/latest/download/` has no
    # index on it and EVERY installed client 404s until it is put back.  That is
    # the worst state this script can leave, so it says so rather than letting
    # `set -e` exit on gh's own message.
    run gh release upload "catalog-$IFACE" --repo "$REPO_SLUG" "$idxdir/$idxasset" ||
        die "$idxasset was deleted from catalog-$IFACE and the upload FAILED.
       The entry point every client compiles in is serving nothing right now.
       Put it back before anything else:
         gh release upload catalog-$IFACE --repo $REPO_SLUG $idxdir/$idxasset"

    # READ THE UPLOAD BACK.  An uploader that reports success is not evidence -
    # see above - and GitHub's `digest` on the stored asset is, for one API call
    # and no download.  A published index that hashes bytes nobody serves is
    # invisible until a user opens the app.
    if [ "$DRY" = "0" ]; then
        want="sha256:$(sha256of "$idxdir/$idxasset")"
        # Separate "GitHub answered, and the answer was empty" from "the call
        # failed": an expired token or a 502 would otherwise be reported as the
        # asset being absent, which is a claim this did not measure.
        got="$(gh release view "catalog-$IFACE" --repo "$REPO_SLUG" --json assets \
               --jq ".assets[] | select(.name == \"$idxasset\") | .digest")" ||
            die "$idxasset was uploaded but the read-back call itself failed, so
       nothing is known about what catalog-$IFACE is serving.  Do not assume this
       publish landed - check it:
         gh release view catalog-$IFACE --repo $REPO_SLUG --json assets"
        if [ "$got" = "$want" ]; then
            note "read back: catalog-$IFACE serves $idxasset at $want"
        elif [ -z "$got" ] || [ "$got" = "null" ]; then
            die "$idxasset is not on catalog-$IFACE after the upload, or GitHub
       reports no digest for it.  Read the stored object back before believing
       this publish:
         gh api repos/$REPO_SLUG/releases/assets/<id> -H 'Accept: application/octet-stream'"
        else
            die "$idxasset was uploaded but catalog-$IFACE still serves
         $got
       and not
         $want
       This is the 2026-09-10 failure.  gh release delete-asset, then upload a
       file whose name on disk is already the published asset name."
        fi
    fi
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
        # DERIVED FROM THE SAME RULE THAT SET THE FLAG, not from a list of
        # status words. This used to be `case "$want:$got" in stable:false|
        # preview:true)`, which enumerated the two status values that existed
        # when it was written - while the create above accepted any status and
        # treated everything non-stable as a prerelease. The two could not
        # disagree about "stable" or "preview", so nothing noticed; the first
        # new status word - "snapshot", added for v3.7.0-dev.14 - created the
        # release CORRECTLY and then failed this check, after every asset had
        # been uploaded to an immutable tag. docs/CATALOG_SCHEMA.md says status
        # is not a closed set, so no list here could have been right for long.
        want_flag="$(gh_prerelease_flag "$want")"
        # gh's field is isPrerelease, not prerelease. A wrong name here does not
        # error out into the comparison - it returns empty and every version
        # looks wrong - so it is worth being exact.
        got="$(gh release view "$tag" --repo "$REPO_SLUG" --json isPrerelease --jq '.isPrerelease' 2>/dev/null || echo unknown)"
        if [ "$got" = "$want_flag" ]; then
            echo "  ok    $tag  status=$want  prerelease=$got"
        else
            echo "  FAIL  $tag  status=$want wants prerelease=$want_flag but GitHub says $got" >&2
            echo "        The index is authoritative for clients; fix the flag or the status." >&2
            rc_flag=1
        fi
    done
    [ -z "${rc_flag:-}" ] || die "the published prerelease flags disagree with the catalog status"
    echo

    # The one flag the whole scheme rests on.  Every client compiles in
    # releases/latest/download/index-v0.json, `gh release create` claims Latest
    # by DEFAULT, and the per-version tags above are created with --latest=false
    # for exactly that reason.  On 2026-09-10 a release cut without it took the
    # flag and that URL answered 404.  check_latest.py is the machine check, and
    # this is the only thing that runs it - it is deliberately not in verify.yml,
    # which tests this repository rather than the release channel.
    echo "=== latest flag ==="
    # It fails for six distinct reasons - no release is Latest, more than one
    # claims it, the Latest release has no index on it, the URL did not fetch,
    # the body is not JSON, the schema is wrong - and it prints which.  So do not
    # restate one of them here as though it were the cause.
    python3 "$ROOT/tools/check_latest.py" --repo "$REPO_SLUG" ||
        die "check_latest.py failed: the URL every installed client compiles in,
       releases/latest/download/index-$IFACE.json, does not resolve to this
       repository's index.  Its message above says which of the six ways.  If the
       flag simply landed on the wrong release:
         gh release edit catalog-$IFACE --repo $REPO_SLUG --latest"
    echo
fi

echo "PASS: published"
echo "  https://github.com/$REPO_SLUG/releases/latest/download/index-$IFACE.json"
