#!/usr/bin/env python3
"""gen_catalog.py - generate the interface-v0 catalog from BUILT artifacts.

Usage: gen_catalog.py <romwbw-version> [...]
       gen_catalog.py --index            (regenerate only the top-level index)

Every size and every sha256 in the published catalog is computed here, from
the file that will actually be uploaded.  Nothing is transcribed.  The catalog
this repo replaces was hand-edited, including its hashes, which is why shipping
it needed a manual pre-flight hash check that a human had to remember to run.

Outputs, per RomWBW version <v>:
  build/v0-romwbw-<v>/catalog-v0-<v>.json   the catalog a client fetches
  build/v0-romwbw-<v>/disks-v0-<v>.xml      the same disks in the legacy
                                            <disks><disk> shape, so a client
                                            can migrate its URL before it
                                            migrates its parser
  catalog/v0/<v>/catalog.json               committed copy, for review and diff

And once:
  build/catalog-v0/index-v0.json            the floating entry point
  catalog/v0/index.json                     committed copy

See docs/CATALOG_SCHEMA.md for the field-by-field contract and
docs/INTERFACE_V0.md for what "v0" promises.
"""
import hashlib
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from xml.dom import minidom

IFACE = "v0"
REPO = "avwohl/romwbw_disks"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")

# The tag that carries the small, mutable index.  Big artifacts never live here
# so re-cutting it costs one upload of a few kilobytes.  Everything else lives
# on an immutable per-version tag, which is what makes a floating entry point
# safe: the thing that moves is tiny and the things clients cache never move.
INDEX_TAG = "catalog-%s" % IFACE
DL = "https://github.com/%s/releases/download" % REPO

# The tag carrying the in-app help topics, mutable for the same reason and with
# the same justification: eight small text files that nothing caches against a
# version.  It is named HERE and nowhere in any client, which is the point - the
# index tells a client where the help is, so this tag can be renamed, re-cut or
# moved to another host without a release of the Windows, Android, iOS or Linux
# client.  A URL compiled into a client would have made that impossible for the
# one subsystem that had no reason to be special.
HELP_TAG = "help-%s" % IFACE

# THE ENTRY POINT EVERY CLIENT COMPILES IN, and the only string any of them has.
#
# `releases/latest/download/` and not `releases/download/catalog-v0/`, because a
# client that names the TAG pins the tag: moving the index, renaming its release
# or reorganising this repository would need a new build of the Windows, Android,
# iOS and Linux clients, all at once, which is the exact coupling this repository
# exists to remove.  GitHub resolves `latest` to whichever release carries the
# flag, so the entry point is ours to move and nobody has to ship anything.
#
# THE INVARIANT THAT BUYS: THE RELEASE MARKED LATEST MUST CARRY index-<iface>.json.
# It is one flag on the whole repository and `gh release create` takes it by
# default, so a per-version release published without --latest=false silently
# repoints every client in the world at a release that has no index on it.  That
# is not hypothetical - it happened on 2026-09-10 when the help-v0 release was
# cut, and `latest/download/index-v0.json` answered 404 until the flag was put
# back.  publish_release.sh passes --latest=false on every other release and
# check_latest.py fails the repository if the flag ever lands anywhere else.
INDEX_LATEST_URL = "https://github.com/%s/releases/latest/download/index-%s.json" % (REPO, IFACE)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load(*parts):
    with open(os.path.join(ROOT, *parts)) as f:
        return json.load(f)


def release_tag(ver):
    return "%s-romwbw-%s" % (IFACE, ver)


def asset_name(stem, ext, ver):
    return "%s-%s-%s%s" % (stem, IFACE, ver, ext)


def diskinfo(path, diskdef):
    out = subprocess.check_output(
        [sys.executable, os.path.join(ROOT, "tools", "diskinfo.py"), path, diskdef])
    return json.loads(out)


def content_digest(rom_entries, disk_entries):
    """Hash of what a catalog actually offers: (filename, sha256) pairs.

    sorted(), not sort_keys=. sort_keys only orders DICT keys, and this payload
    is a list of lists - so without the explicit sort, merely reordering
    entries in versions/<ver>/disks.json changed the digest and bumped the
    generation, which on iOS deletes every downloaded image. Reordering a
    manifest must be a no-op.
    """
    payload = json.dumps(sorted(
        [[e["filename"], e["sha256"]] for e in rom_entries]
        + [[e["filename"], e["sha256"]] for e in disk_entries])).encode()
    return hashlib.sha256(payload).hexdigest()


def catalog_generation(ver, disk_entries, rom_entries):
    """A monotonic integer that changes only when the artifacts change.

    iOS compares this against a stored value and DELETES downloaded images when
    it differs (checkCatalogVersionAndInvalidate).  So it must not move when
    nothing moved - a hand-incremented number does, and a hash of the content
    is not monotonic.  Both properties are needed, so: hash the content, and
    bump a stored counter only when the hash changes.

    The counter is per RomWBW version.  Switching between RomWBW versions is
    not a catalog bump; without that separation a user toggling
    3.5.1 -> 3.6.0 -> 3.5.1 would have their library deleted twice.
    """
    # sorted(), not sort_keys=. sort_keys only orders DICT keys, and this
    # payload is a list of lists - so without the explicit sort, merely
    # reordering entries in versions/<ver>/disks.json changed the digest and
    # bumped the generation, which on iOS deletes every downloaded image.
    # Reordering a manifest must be a no-op.
    digest = content_digest(rom_entries, disk_entries)

    path = os.path.join(ROOT, "versions", ver, "generation.json")
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {"generation": 0, "content_sha256": None}

    # The counter must never go backwards. A deleted or reverted
    # generation.json would otherwise reset it to 1, and a client that already
    # saw a higher number would either miss a real change or see a spurious
    # one. The floor is the generation in the committed catalog, which is in
    # git and therefore survives losing generation.json.
    floor, floor_digest = 0, None
    committed = os.path.join(ROOT, "catalog", IFACE, ver, "catalog.json")
    try:
        with open(committed) as f:
            prev = json.load(f)
        floor = int(prev.get("generation", 0))
        floor_digest = content_digest(prev.get("roms", []), prev.get("disks", []))
    except (FileNotFoundError, ValueError, TypeError, KeyError):
        pass

    current = int(state.get("generation", 0) or 0)
    if state.get("content_sha256") == digest and current >= floor:
        return current

    if digest == floor_digest:
        # The artifacts are what the committed catalog already describes, so
        # this is a lost or stale generation.json, not a content change. Adopt
        # the published number rather than inventing a new one - a spurious
        # bump deletes every user's downloaded images.
        nxt = max(current, floor)
    else:
        nxt = max(current, floor) + 1
    state = {
        "generation": nxt,
        "content_sha256": digest,
        "_comment": "Written by tools/gen_catalog.py. The generation only "
                    "advances when content_sha256 changes, and never "
                    "decreases; do not edit by hand. iOS deletes downloaded "
                    "images when it changes.",
    }
    with open(path, "w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    return state["generation"]


def build_catalog(ver):
    vmeta = load("versions", ver, "version.json")
    roms = load("versions", ver, "roms.json")["roms"]
    disks = load("versions", ver, "disks.json")["disks"]
    tag = release_tag(ver)
    outdir = os.path.join(BUILD, tag)
    if not os.path.isdir(outdir):
        sys.exit("gen_catalog: %s does not exist - run tools/build_version.sh %s"
                 % (outdir, ver))

    base_url = "%s/%s/" % (DL, tag)

    rom_entries = []
    for r in roms:
        fn = asset_name(r["id"], ".rom", ver)
        p = os.path.join(outdir, fn)
        if not os.path.exists(p):
            sys.exit("gen_catalog: missing built ROM %s" % p)
        with open(p, "rb") as f:
            f.seek(0x100)
            hcb = f.read(8)
        rom_entries.append({
            "id": r["id"],
            "filename": fn,
            "name": r["name"],
            "description": r["description"],
            "size": os.path.getsize(p),
            "sha256": sha256(p),
            "default": bool(r.get("default")),
            # The bytes emu_validate_rom_hcb reads back at load time.  A client
            # can reject a mismatched ROM before downloading 512KB of it.
            "hcb": {
                "marker": "%02X %02X" % (hcb[3], hcb[4]),
                "version": "0x%02X" % hcb[5],
                "update": "0x%02X" % hcb[6],
                "platform": hcb[7],
            },
            "built_from": {
                "bank0": "src/emu_hbios.asm",
                "banks_1_15": r["stock"],
            },
        })

    disk_entries = []
    for d in disks:
        fn = asset_name(d["id"], ".img", ver)
        p = os.path.join(outdir, fn)
        if not os.path.exists(p):
            sys.exit("gen_catalog: missing built image %s" % p)
        probe = d["inject_utils"][0] if d.get("inject_utils") else d["diskdef"]
        info = diskinfo(p, probe)
        e = {
            "id": d["id"],
            "filename": fn,
            "name": d["name"],
            "description": d["description"],
            "size": os.path.getsize(p),
            "sha256": sha256(p),
            "license": d["license"],
            "format": "hd1k_combo" if d["diskdef"].startswith("wbw_hd1k_") else "hd1k",
            "bootable": info["bootable"],
            # The CBIOS banner assembled into the boot slice.  It has to agree
            # with the ROM's HCB or the guest prints
            # "*** WARNING: HBIOS/CBIOS Version Mismatch ***" at boot.
            "cbios": info["cbios"],
            # Whether this image carries the W8/R8 host file transfer pair.
            # Stated, not implied by the description, because a client can use
            # it to decide whether to offer host transfer at all.
            "host_transfer": bool(info["utils"]),
            "upstream": d["upstream"],
        }
        if "slices" in d:
            e["slices"] = d["slices"]
        if "defaultSlot" in d:
            e["defaultSlot"] = d["defaultSlot"]
        disk_entries.append(e)

    cat = {
        "schema": "romwbw-disks-catalog",
        "schema_version": 1,
        "interface": IFACE,
        "romwbw_version": ver,
        "generation": catalog_generation(ver, disk_entries, rom_entries),
        "status": vmeta["status"],
        "release_tag": tag,
        "base_url": base_url,
        "hbios": vmeta["hbios"],
        "upstream": {
            "tag": vmeta["upstream"]["tag"],
            "package_url": vmeta["upstream"]["package_url"],
            "package_sha256": vmeta["upstream"].get("package_sha256"),
        },
        "notes": vmeta.get("notes", []),
        "roms": rom_entries,
        "disks": disk_entries,
    }

    cpath = os.path.join(outdir, asset_name("catalog", ".json", ver))
    with open(cpath, "w") as f:
        json.dump(cat, f, indent=2)
        f.write("\n")

    tracked = os.path.join(ROOT, "catalog", IFACE, ver)
    os.makedirs(tracked, exist_ok=True)
    with open(os.path.join(tracked, "catalog.json"), "w") as f:
        json.dump(cat, f, indent=2)
        f.write("\n")

    write_legacy_xml(cat, os.path.join(outdir, asset_name("disks", ".xml", ver)))

    print("  %-34s %6d bytes  %d ROMs  %d disks"
          % (os.path.basename(cpath), os.path.getsize(cpath),
             len(rom_entries), len(disk_entries)))
    return cat, cpath


def write_legacy_xml(cat, path):
    """The same disks in the shipped <disks version="N"> shape.

    A client can point at this URL before it learns the JSON schema, which lets
    the URL migration and the parser migration be two separate releases.

    The version attribute is the CATALOG GENERATION, and on iOS a change to it
    deletes downloaded images (checkCatalogVersionAndInvalidate).  It is
    therefore derived from the content, not incremented by hand, and it is
    per-(interface, RomWBW version): switching between RomWBW versions must not
    look like a catalog bump, or a user toggling 3.5.1 -> 3.6.0 -> 3.5.1 has
    their library deleted twice.
    """
    root = ET.Element("disks")
    root.set("version", str(cat["generation"]))
    root.set("interface", cat["interface"])
    root.set("romwbw", cat["romwbw_version"])
    for d in cat["disks"]:
        e = ET.SubElement(root, "disk")
        for k in ("filename", "name", "description"):
            ET.SubElement(e, k).text = d[k]
        ET.SubElement(e, "size").text = str(d["size"])
        ET.SubElement(e, "license").text = d["license"]
        ET.SubElement(e, "sha256").text = d["sha256"]
        if "defaultSlot" in d:
            ET.SubElement(e, "defaultSlot").text = str(d["defaultSlot"])
    xml = minidom.parseString(ET.tostring(root, "utf-8")).toprettyxml(indent="    ")
    with open(path, "w") as f:
        f.write(xml)


def build_help():
    """The `help` block: the in-app help topics, shaped like every other asset.

    HELP IS A CATALOG ENTRY, not a pointer at a second index.  It used to be
    {"index_url": ..., "base_url": ...} naming a separate help_index.json, and
    that was a second way of doing what disks[] and roms[] already do: a list of
    files with an id, a filename, a size and a sha256 under one base_url.  The
    separate document meant one more fetch, one more parse, one more thing to
    keep in step - and help was the only content this repository published that
    nothing verified.  Now it is checked on arrival like a ROM or a disk.

    It lives in the INDEX and not in a per-version catalog, and that is
    deliberate: the topics are about CP/M and the applications, not about RomWBW
    3.5.1 versus 3.6.0.  Putting them in a per-version catalog would copy them
    into every release and make fixing a typo mean re-cutting a 200 MB tag.  The
    index is the small mutable document; re-cutting it is what publishing is.

    Metadata is authored in help/topics.json; the sizes and hashes are measured
    here, so they cannot be authored wrong.
    """
    src = json.load(open(os.path.join(ROOT, "help", "topics.json")))
    topics = []
    for t in src["topics"]:
        path = os.path.join(ROOT, "help", t["filename"])
        if not os.path.exists(path):
            sys.exit("gen_catalog: help/%s is listed in help/topics.json and is not "
                     "in the checkout." % t["filename"])
        topics.append({
            "id": t["id"],
            "filename": t["filename"],
            "name": t["name"],
            "description": t["description"],
            "size": os.path.getsize(path),
            "sha256": sha256(path),
        })
    return {
        "base_url": "%s/%s/" % (DL, HELP_TAG),
        "topics": topics,
    }


def build_index(versions):
    entries = []
    for ver in versions:
        tag = release_tag(ver)
        cpath = os.path.join(BUILD, tag, asset_name("catalog", ".json", ver))
        if not os.path.exists(cpath):
            # Never quietly publish an index that omits a version. The index is
            # the entry point; a version missing from it is invisible to every
            # client, and this used to happen with no message at all.
            sys.exit("gen_catalog: %s is not built, so the index would omit "
                     "RomWBW %s.\n  Run: tools/build_all.sh %s"
                     % (os.path.basename(cpath), ver, ver))
        cat = json.load(open(cpath))
        vmeta = load("versions", ver, "version.json")
        entries.append({
            "romwbw_version": ver,
            "label": "RomWBW %s" % ver,
            "status": vmeta["status"],
            "default": bool(vmeta.get("default")),
            "released": vmeta.get("released"),
            "hbios": vmeta["hbios"],
            "release_tag": tag,
            "catalog_url": cat["base_url"] + os.path.basename(cpath),
            "catalog_sha256": sha256(cpath),
            "catalog_size": os.path.getsize(cpath),
            "generation": cat["generation"],
            "disks_xml_url": cat["base_url"] + asset_name("disks", ".xml", ver),
            "rom_count": len(cat["roms"]),
            "disk_count": len(cat["disks"]),
            "notes": vmeta.get("notes", []),
        })

    idx = {
        "schema": "romwbw-disks-index",
        "schema_version": 1,
        "interface": IFACE,
        "repo": "https://github.com/%s" % REPO,
        # This document is the one thing that moves.  Its URL is stable and its
        # content changes when a RomWBW version is added or promoted, so a
        # client never needs a new build to see a new version.
        "index_url": INDEX_LATEST_URL,
        # The in-app help, as catalog data rather than as a pointer at another
        # document.  See build_help().
        "help": build_help(),
        "romwbw_versions": entries,
    }
    outdir = os.path.join(BUILD, INDEX_TAG)
    os.makedirs(outdir, exist_ok=True)
    p = os.path.join(outdir, "index-%s.json" % IFACE)
    with open(p, "w") as f:
        json.dump(idx, f, indent=2)
        f.write("\n")
    tracked = os.path.join(ROOT, "catalog", IFACE, "index.json")
    os.makedirs(os.path.dirname(tracked), exist_ok=True)
    with open(tracked, "w") as f:
        json.dump(idx, f, indent=2)
        f.write("\n")
    print("  %-34s %6d bytes  %d RomWBW version(s): %s"
          % (os.path.basename(p), os.path.getsize(p), len(entries),
             ", ".join(e["romwbw_version"] for e in entries)))
    return idx


def all_versions():
    d = os.path.join(ROOT, "versions")
    return sorted(v for v in os.listdir(d)
                  if os.path.isfile(os.path.join(d, v, "version.json")))


def main():
    args = sys.argv[1:]
    versions = all_versions()
    if args and args[0] == "--index":
        build_index(versions)
        return
    targets = args or versions
    print("Generating interface-%s catalogs" % IFACE)
    for ver in targets:
        build_catalog(ver)
    build_index(versions)
    print("PASS: catalogs generated")


if __name__ == "__main__":
    main()
