#!/usr/bin/env python3
"""check_committed.py - check the committed catalogs without building anything.

Usage: tools/check_committed.py

The full pipeline needs ~420MB of upstream downloads and a Z80 toolchain. This
does not. It checks the things that can go wrong from an editing mistake rather
than a build failure, so it can run on every push:

  - the committed catalog/ documents parse and carry the fields the schema says
  - every disk and ROM in versions/<ver>/{disks,roms}.json appears in that
    version's catalog, and nothing appears that is not in a manifest
  - filenames follow the <id>-<iface>-<ver>.<ext> convention
  - index entries and catalogs agree on version, generation and counts
  - exactly one RomWBW version is marked default
  - generation.json's recorded content hash matches the catalog it describes
  - the index's help block - its topic list, order, sizes and sha256s - is
    re-derived from help/ rather than trusted, because nothing else did
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_catalog  # noqa: E402

IFACE = "v0"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

problems = []


def bad(msg):
    problems.append(msg)
    print("FAIL  %s" % msg)


def info(msg):
    # Said out loud but not counted. Reserved for a divergence that is expected
    # and explained; anything that might be a mistake goes through bad().
    print("info  %s" % msg)


def load(*p):
    with open(os.path.join(ROOT, *p)) as f:
        return json.load(f)


def check_help(index):
    """The index's help block, re-derived from help/ rather than trusted.

    The seven topics are published on their own tag and named by the index with a
    size and a sha256 each. Nothing in this tree re-derived them: editing a topic
    and forgetting to regenerate committed an index whose hashes describe the
    previous text, and a client checks a topic against them on arrival and falls
    back to its own bundled copy when they disagree - so a stale entry means every
    reader silently gets the version compiled into their app, for the topics that
    changed. The derivation is gen_catalog's own build_help(), called rather than
    copied, so this cannot disagree with what a publish would write. It reads
    seven small files and no network, which is why it belongs in the every-push
    check; the remedy when it fires is `tools/gen_catalog.py --help-block`, which
    needs no build either.
    """
    before = len(problems)
    try:
        want = gen_catalog.build_help()
    except SystemExit as e:
        # build_help exits on a listed topic that is not in the checkout, or an
        # unlisted help_*.md. Both are real problems, but they belong in this
        # script's tally rather than killing it mid-run.
        bad("help/: %s" % str(e).replace("gen_catalog: ", ""))
        return
    except (OSError, ValueError) as e:
        bad("help/topics.json could not be read: %s" % e)
        return
    got = index.get("help")
    if not got:
        bad("the index carries no help block")
        return
    if got.get("base_url") != want["base_url"]:
        bad("index help base_url is %r, expected %r"
            % (got.get("base_url"), want["base_url"]))
    want_order = [t["filename"] for t in want["topics"]]
    got_order = [t["filename"] for t in got.get("topics", [])]
    if got_order != want_order:
        # Order, not just membership: a client renders the list in array order,
        # so the sequence is part of what is published.
        if sorted(got_order) == sorted(want_order):
            bad("index help lists the right topics in the wrong order: %s, "
                "help/topics.json gives %s" % (got_order, want_order))
        else:
            bad("index help lists %s but help/topics.json lists %s"
                % (got_order, want_order))
    wt = dict((t["filename"], t) for t in want["topics"])
    gt = dict((t["filename"], t) for t in got.get("topics", []))
    for fn in sorted(set(wt) & set(gt)):
        for k in ("id", "name", "description", "size", "sha256"):
            if gt[fn].get(k) != wt[fn][k]:
                bad("index help topic %s: %s is %r, help/%s gives %r"
                    % (fn, k, gt[fn].get(k), fn, wt[fn][k]))
    if len(problems) == before:
        print("ok    help  %d topics, in order, every size and sha256 re-derived "
              "from help/" % len(gt))
    else:
        # Name the remedy where the failure is read.  It needs no build, which is
        # the whole reason this check can live in the every-push job.
        print("      fix: python3 tools/gen_catalog.py --help-block")


def main():
    index = load("catalog", IFACE, "index.json")
    if index.get("interface") != IFACE:
        bad("index interface is %r, expected %r" % (index.get("interface"), IFACE))

    defaults = [e["romwbw_version"] for e in index["romwbw_versions"] if e.get("default")]
    if len(defaults) != 1:
        bad("index marks %d default versions (%s), expected exactly 1"
            % (len(defaults), ", ".join(defaults) or "none"))

    # A SNAPSHOT MUST NEVER BE THE DEFAULT.  This is the invariant that makes
    # carrying one safe at all: it is reachable only by a user who went looking
    # for it, never by a client picking the default. The two flags are written
    # independently in versions/<ver>/version.json, so nothing but this stops
    # a later edit from setting both.
    for e in index["romwbw_versions"]:
        if e.get("prerelease") and e.get("default"):
            bad("%s is marked prerelease AND default - a development snapshot "
                "must never be what a client picks on its own"
                % e["romwbw_version"])

    versions = sorted(v for v in os.listdir(os.path.join(ROOT, "versions"))
                      if os.path.isdir(os.path.join(ROOT, "versions", v)))
    listed = sorted(e["romwbw_version"] for e in index["romwbw_versions"])
    if listed != versions:
        bad("index lists %s but versions/ holds %s" % (listed, versions))

    # AND IN THE RIGHT ORDER.  The comparison above sorts both sides, so it
    # says the right versions are present and nothing at all about the order
    # they are in - while docs/CATALOG_SCHEMA.md now documents that order as
    # part of the contract, and a client showing a picker renders it verbatim.
    # A hand edit or a half-finished regeneration could reorder the committed
    # index and pass every check on every push.
    want_order = gen_catalog.all_versions()
    got_order = [e["romwbw_version"] for e in index["romwbw_versions"]]
    if got_order != want_order:
        bad("index lists versions in the order %s; semver precedence is %s.\n"
            "      fix: python3 tools/gen_catalog.py --index"
            % (got_order, want_order))

    # AT MOST ONE SNAPSHOT AT A TIME.  CLAUDE.md sets the policy and this is
    # the cheap half of enforcing it: each snapshot is ~250MB of published
    # assets that no client selects by default, so letting them accumulate
    # costs storage and gives a user a list of near-identical development
    # builds to choose wrongly between. Adding dev.15 means deleting dev.14 in
    # the same commit.
    snaps = [e["romwbw_version"] for e in index["romwbw_versions"]
             if e.get("prerelease")]
    if len(snaps) > 1:
        bad("index carries %d development snapshots (%s); carry one at a time "
            "- delete the superseded versions/<ver>/ and catalog/v0/<ver>/ in "
            "the commit that adds the new one (CLAUDE.md)"
            % (len(snaps), ", ".join(snaps)))

    # NO TWO ENTRIES MAY SHARE AN HCB.  The four bytes at 0x103 are what every
    # client validates a ROM against, and they are ALL a client can filter on -
    # docs/CATALOG_SCHEMA.md says so. v3.7.0-dev.14 reads 57 a8 37 00, byte for
    # byte what a released 3.7.0 will read, so the day both are in the index
    # there are two entries a client cannot tell apart by the only bytes it
    # has. Each entry is individually correct, which is why nothing else here
    # notices; the collision exists only BETWEEN them.
    #
    # CLAUDE.md's rule is to retire the snapshot in the commit that adds the
    # release. This is that rule with teeth: it fires whatever the cause, so it
    # also catches two versions that simply got the same hbios block wrong.
    by_hcb = {}
    for e in index["romwbw_versions"]:
        h = e.get("hbios") or {}
        key = (h.get("ver_byte"), h.get("upd_byte"))
        by_hcb.setdefault(key, []).append(e["romwbw_version"])
    for key, vers in sorted(by_hcb.items()):
        if len(vers) > 1:
            bad("%s share the HCB bytes %s/%s, which is all a client can "
                "filter a ROM on - it cannot tell them apart. Retire the "
                "snapshot in the commit that adds its release (CLAUDE.md)."
                % (" and ".join(vers), key[0], key[1]))

    # THE DIRECTORY NAME IS THE VERSION, and the JSON field is decoration.
    # Nothing reads romwbw_version out of versions/<ver>/*.json - gen_catalog
    # takes the version from the directory name it was handed, and that name is
    # what becomes the expected CBIOS banner, every asset name and the release
    # tag. So a wrong romwbw_version in a manifest is invisible and would sit
    # there contradicting the tree. Cheap to check, so check it.
    for ver in versions:
        for fn in ("version.json", "roms.json", "disks.json"):
            doc = load("versions", ver, fn)
            got = doc.get("romwbw_version")
            if got != ver:
                bad("versions/%s/%s says romwbw_version=%r but the directory - "
                    "which is what the build actually uses - is %r"
                    % (ver, fn, got, ver))

    # THE prerelease FLAG IS DERIVED, NOT TRUSTED.  It is hand-authored in
    # versions/<ver>/version.json, and everything that keeps a snapshot out of
    # a client's default hangs off it. Omit the line on the next snapshot -
    # versions/3.7.0-dev.15/, say - and every check here would pass while the
    # entry became an ordinary-looking release. The upstream tag already knows:
    # a plain vX.Y.Z is a release, anything else is not.
    for ver in versions:
        vmeta = load("versions", ver, "version.json")
        tag = vmeta["upstream"]["tag"]
        derived = re.fullmatch(r"v\d+\.\d+\.\d+", tag) is None
        if bool(vmeta.get("prerelease")) != derived:
            bad("%s: upstream tag %r says prerelease=%s but version.json says "
                "%s. A snapshot must declare itself; a real release must not."
                % (ver, tag, derived, bool(vmeta.get("prerelease"))))
        for label, doc in (("index entry",
                            next((e for e in index["romwbw_versions"]
                                  if e["romwbw_version"] == ver), {})),
                           ("catalog",
                            load("catalog", IFACE, ver, "catalog.json"))):
            if bool(doc.get("prerelease")) != derived:
                bad("%s %s says prerelease=%s, derived from tag %r it is %s"
                    % (ver, label, bool(doc.get("prerelease")), tag, derived))

    for ver in versions:
        cat = load("catalog", IFACE, ver, "catalog.json")
        disks = load("versions", ver, "disks.json")["disks"]
        roms = load("versions", ver, "roms.json")["roms"]
        vmeta = load("versions", ver, "version.json")

        if cat["romwbw_version"] != ver:
            bad("%s catalog says romwbw_version=%r" % (ver, cat["romwbw_version"]))
        if cat["release_tag"] != "%s-romwbw-%s" % (IFACE, ver):
            bad("%s release_tag is %r" % (ver, cat["release_tag"]))
        # status is the ONE field allowed to differ here, and only in this
        # direction: the per-version catalog is published on the immutable tag
        # v0-romwbw-<ver> and records what the version was when its assets were
        # cut, while version.json and the index carry the live value. Promoting
        # preview -> stable moves the live value and must NOT re-cut a published
        # asset, so the two legitimately diverge from that moment on.
        #
        # The invariant that actually protects a client is the index one below,
        # because the index is what a client reads status from (CATALOG_SCHEMA
        # section 6, RELEASING section 6) - and that one stays a hard failure.
        # Promotion is one-way, so a catalog claiming 'stable' while the manifest
        # says 'preview' is not a promotion and is still an error.
        if cat["status"] != vmeta["status"]:
            if cat["status"] == "preview" and vmeta["status"] == "stable":
                info("%s catalog says 'preview' and version.json says 'stable' - "
                     "promoted after its assets were cut, which is expected; the "
                     "index is authoritative and is checked below" % ver)
            else:
                bad("%s status %r disagrees with version.json %r"
                    % (ver, cat["status"], vmeta["status"]))
        if cat["hbios"] != vmeta["hbios"]:
            bad("%s catalog hbios block disagrees with version.json" % ver)
        if not cat["base_url"].endswith("/%s/" % cat["release_tag"]):
            bad("%s base_url %r does not end in its release tag" % (ver, cat["base_url"]))

        for kind, manifest, entries in (("rom", roms, cat["roms"]),
                                        ("disk", disks, cat["disks"])):
            want = [m["id"] for m in manifest]
            got = [e["id"] for e in entries]
            if want != got:
                bad("%s %s ids differ.\n      manifest: %s\n      catalog:  %s"
                    % (ver, kind, want, got))
            ext = ".rom" if kind == "rom" else ".img"
            for e in entries:
                expect = "%s-%s-%s%s" % (e["id"], IFACE, ver, ext)
                if e["filename"] != expect:
                    bad("%s %s filename %r should be %r" % (ver, kind, e["filename"], expect))
                if len(e.get("sha256", "")) != 64:
                    bad("%s %s %s has no usable sha256" % (ver, kind, e["id"]))
                if not isinstance(e.get("size"), int) or e["size"] <= 0:
                    bad("%s %s %s has no usable size" % (ver, kind, e["id"]))

        rom_defaults = [r for r in cat["roms"] if r.get("default")]
        if len(rom_defaults) != 1:
            bad("%s marks %d default ROMs, expected exactly 1" % (ver, len(rom_defaults)))

        # The generation counter must describe THIS catalog's content, or the
        # value clients use to decide whether to invalidate is meaningless.
        gen = load("versions", ver, "generation.json")
        # The SAME function the generator uses, imported rather than
        # reimplemented: two copies of this drifted apart once already, and a
        # checker that hashes differently from the generator reports a
        # permanent, meaningless failure.
        digest = gen_catalog.content_digest(cat["roms"], cat["disks"])
        if gen.get("content_sha256") != digest:
            bad("%s generation.json content_sha256 does not describe the committed "
                "catalog - regenerate with tools/gen_catalog.py" % ver)
        if gen.get("generation") != cat.get("generation"):
            bad("%s generation.json says %r, catalog says %r"
                % (ver, gen.get("generation"), cat.get("generation")))

        entry = next((e for e in index["romwbw_versions"]
                      if e["romwbw_version"] == ver), None)
        if entry is None:
            bad("%s has a committed catalog but no index entry - it would be "
                "invisible to every client" % ver)
            continue

        # The index is what a client reads FIRST, and until now nothing
        # compared its per-version fields against the version manifest. An
        # index could name the wrong default, or a status and HCB bytes that
        # disagreed with the catalog it points at, and every check still
        # passed.
        if bool(entry.get("default")) != bool(vmeta.get("default")):
            bad("%s index default=%r disagrees with version.json default=%r"
                % (ver, entry.get("default"), vmeta.get("default")))
        if entry.get("status") != vmeta["status"]:
            bad("%s index status %r disagrees with version.json %r"
                % (ver, entry.get("status"), vmeta["status"]))
        if entry.get("hbios") != vmeta["hbios"]:
            bad("%s index hbios block disagrees with version.json" % ver)
        if entry.get("hbios") != cat["hbios"]:
            bad("%s index hbios block disagrees with the catalog it points at" % ver)
        if entry.get("released") != vmeta.get("released"):
            bad("%s index released %r disagrees with version.json %r"
                % (ver, entry.get("released"), vmeta.get("released")))
        if entry.get("release_tag") != cat["release_tag"]:
            bad("%s index release_tag %r disagrees with the catalog %r"
                % (ver, entry.get("release_tag"), cat["release_tag"]))

        if entry["generation"] != cat["generation"]:
            bad("%s index generation %r disagrees with catalog %r"
                % (ver, entry["generation"], cat["generation"]))
        if entry["rom_count"] != len(cat["roms"]) or entry["disk_count"] != len(cat["disks"]):
            bad("%s index counts (%d roms, %d disks) disagree with the catalog (%d, %d)"
                % (ver, entry["rom_count"], entry["disk_count"],
                   len(cat["roms"]), len(cat["disks"])))
        if not entry["catalog_url"].startswith(cat["base_url"]):
            bad("%s index catalog_url is not under the catalog's own base_url" % ver)

        print("ok    %s  generation %d  %d roms  %d disks  status=%s"
              % (ver, cat["generation"], len(cat["roms"]), len(cat["disks"]), cat["status"]))

    check_help(index)

    if problems:
        print("\nFAIL: %d problem(s)" % len(problems))
        sys.exit(1)
    print("\nPASS: committed catalogs are consistent")


if __name__ == "__main__":
    main()
