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
"""
import json
import os
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


def main():
    index = load("catalog", IFACE, "index.json")
    if index.get("interface") != IFACE:
        bad("index interface is %r, expected %r" % (index.get("interface"), IFACE))

    defaults = [e["romwbw_version"] for e in index["romwbw_versions"] if e.get("default")]
    if len(defaults) != 1:
        bad("index marks %d default versions (%s), expected exactly 1"
            % (len(defaults), ", ".join(defaults) or "none"))

    versions = sorted(v for v in os.listdir(os.path.join(ROOT, "versions"))
                      if os.path.isdir(os.path.join(ROOT, "versions", v)))
    listed = sorted(e["romwbw_version"] for e in index["romwbw_versions"])
    if listed != versions:
        bad("index lists %s but versions/ holds %s" % (listed, versions))

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

    if problems:
        print("\nFAIL: %d problem(s)" % len(problems))
        sys.exit(1)
    print("\nPASS: committed catalogs are consistent")


if __name__ == "__main__":
    main()
