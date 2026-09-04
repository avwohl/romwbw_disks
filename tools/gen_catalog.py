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
    payload = json.dumps(
        [[e["filename"], e["sha256"]] for e in rom_entries]
        + [[e["filename"], e["sha256"]] for e in disk_entries],
        sort_keys=True).encode()
    digest = hashlib.sha256(payload).hexdigest()

    path = os.path.join(ROOT, "versions", ver, "generation.json")
    try:
        with open(path) as f:
            state = json.load(f)
    except FileNotFoundError:
        state = {"generation": 0, "content_sha256": None}

    if state.get("content_sha256") != digest:
        state = {
            "generation": int(state.get("generation", 0)) + 1,
            "content_sha256": digest,
            "_comment": "Written by tools/gen_catalog.py. The generation only "
                        "advances when content_sha256 changes; do not edit by "
                        "hand. iOS deletes downloaded images when it changes.",
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


def build_index(versions):
    entries = []
    for ver in versions:
        tag = release_tag(ver)
        cpath = os.path.join(BUILD, tag, asset_name("catalog", ".json", ver))
        if not os.path.exists(cpath):
            continue
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
        "index_url": "%s/%s/index-%s.json" % (DL, INDEX_TAG, IFACE),
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
