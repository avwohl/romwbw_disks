#!/usr/bin/env python3
"""verify_catalog.py - re-derive every claim a catalog makes.

Usage: verify_catalog.py <catalog.json> <asset-dir>
       verify_catalog.py --index <index.json> <build-dir>

Deliberately independent of gen_catalog.py: it re-reads the artifacts and
re-computes, so a bug in the generator cannot certify its own output.  It also
works against a directory of DOWNLOADED assets, which is how a published
release is checked from outside.
"""
import hashlib
import json
import os
import re
import sys

BOOT_TRACK_BYTES = 2 * 16 * 512
SLICE_BYTES = 8 * 1024 * 1024
COMBO_PREFIX_BYTES = 1024 * 1024
BANNER = re.compile(rb"CBIOS v([0-9][0-9A-Za-z.\-]*) \[([A-Z]+)\]")

# `ld b,HBF_HOST_CAPS` / `rst 8` - W8's probe for CAP_SAFE_PATHS.  W8 refuses to
# hand a host path to an emulator that does not answer it.
W8_INTERLOCK = bytes((0x06, 0xE9, 0xCF))

# Per-call, not module-global: these functions return a boolean so they can be
# used as a library, and a shared list meant a second call in one process could
# never return True.
_fails = []


def fail(msg):
    _fails.append(msg)
    print("  FAIL  %s" % msg)


def ok(msg):
    print("  ok    %s" % msg)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# hd1k disk parameters, from the wbw_hd1k diskdef in tools/diskdefs:
#   seclen 512, sectrk 16, tracks 1024, blocksize 4096, maxdir 1024, boottrk 2
# DSM works out above 255, so block pointers are 16-bit (8 per entry), and
# EXM is 1, so one directory entry covers two logical extents (256 records).
BLOCK_BYTES = 4096
EXM = 1
RECORD_BYTES = 128
DIR_ENTRIES = 1024


def extract_file(data, base, want):
    """Return the bytes of one file from the CP/M directory at `base`.

    Needed so the W8 interlock is checked against w8.com itself. Searching the
    whole 51MB image for three bytes is not a check: a combo contains
    06 e9 cf somewhere by chance, so an image-wide search passes on a w8.com
    that has lost the probe entirely.

    Returns None if the file is absent or its allocation cannot be followed.
    """
    dir_start = base + BOOT_TRACK_BYTES
    data_start = base + BOOT_TRACK_BYTES
    entries = []
    for i in range(DIR_ENTRIES):
        e = data[dir_start + i * 32: dir_start + (i + 1) * 32]
        if len(e) < 32 or e[0] != 0x00:
            continue
        nm = bytes(b & 0x7F for b in e[1:9]).decode("ascii", "replace").strip()
        ex = bytes(b & 0x7F for b in e[9:12]).decode("ascii", "replace").strip()
        full = (nm + "." + ex if ex else nm).lower()
        if full != want:
            continue
        extent = ((e[14] & 0x3F) << 5) | (e[12] & 0x1F)
        blocks = [e[16 + 2 * j] | (e[17 + 2 * j] << 8) for j in range(8)]
        entries.append((extent, e[15], blocks))
    if not entries:
        return None

    entries.sort()
    out = bytearray()
    for _, _, blocks in entries:
        for b in blocks:
            if b == 0:
                continue
            off = data_start + b * BLOCK_BYTES
            if off + BLOCK_BYTES > len(data):
                return None
            out += data[off: off + BLOCK_BYTES]

    # Size from the last entry: records before it, plus the records it holds.
    last_extent, rc, _ = entries[-1]
    records = (last_extent & ~EXM) * 128 + rc
    size = records * RECORD_BYTES
    if size == 0 or size > len(out):
        return bytes(out)
    return bytes(out[:size])


def check_asset(entry, adir):
    """Presence, size and hash. Returns the path, or None if it is unusable."""
    p = os.path.join(adir, entry["filename"])
    if not os.path.exists(p):
        fail("%s is missing" % entry["filename"])
        return None
    size = os.path.getsize(p)
    if size != entry["size"]:
        fail("%s is %d bytes, catalog says %d" % (entry["filename"], size, entry["size"]))
        return None
    got = sha256(p)
    if got != entry["sha256"]:
        fail("%s sha256 %s, catalog says %s" % (entry["filename"], got, entry["sha256"]))
        return None
    return p


def verify_catalog(cat_path, adir):
    del _fails[:]
    cat = json.load(open(cat_path))
    ver = cat["romwbw_version"]
    hb = cat["hbios"]
    want_hcb = bytes((0x57, 0xA8, (hb["major"] << 4) | hb["minor"],
                      (hb["update"] << 4) | hb["patch"]))
    want_banner = ("CBIOS v%s [WBW]" % ver).encode()

    print("catalog %s  interface %s  RomWBW %s  generation %s"
          % (os.path.basename(cat_path), cat["interface"], ver, cat.get("generation")))

    if not cat["roms"] or not cat["disks"]:
        fail("catalog describes %d ROMs and %d disks - an empty catalog must "
             "never verify clean" % (len(cat["roms"]), len(cat["disks"])))

    for r in cat["roms"]:
        p = check_asset(r, adir)
        if not p:
            continue
        with open(p, "rb") as f:
            f.seek(0x103)
            hcb = f.read(4)
        if hcb != want_hcb:
            fail("%s HCB at 0x103 is %s, expected %s - no client could load it"
                 % (r["filename"], hcb.hex(), want_hcb.hex()))
            continue
        # Banks 1-15 must come from the same release.  The ROM disk carries the
        # CBIOS the boot loader would hand to a guest, so its banner is checked
        # too - this is what would catch a dev snapshot used as banks 1-15.
        banners = {m.group(0) for m in BANNER.finditer(open(p, "rb").read())}
        bad = [b.decode() for b in banners if b != want_banner]
        if bad:
            fail("%s carries a foreign CBIOS banner: %s" % (r["filename"], ", ".join(sorted(bad))))
            continue
        ok("%s  HCB %s  %d bytes" % (r["filename"], hcb.hex(), r["size"]))

    for d in cat["disks"]:
        p = check_asset(d, adir)
        if not p:
            continue
        data = open(p, "rb").read()
        combo = d["format"] == "hd1k_combo"
        base = COMBO_PREFIX_BYTES if combo else 0
        bad_here = False

        # EVERY slice of a combo, not just slice 0. A combo is six independent
        # boot slices; checking one of them and reporting on the image is how a
        # disk whose slice 3 came from another RomWBW release would ship
        # looking clean, then warn at boot the moment a user booted that slice.
        if combo:
            nslices = int(d.get("slices", (len(data) - COMBO_PREFIX_BYTES) // SLICE_BYTES))
            spans = [(i, data[COMBO_PREFIX_BYTES + i * SLICE_BYTES:
                              COMBO_PREFIX_BYTES + (i + 1) * SLICE_BYTES])
                     for i in range(nslices)]
        else:
            spans = [(None, data)]

        all_banners = set()
        for idx, span in spans:
            banners = {m.group(0) for m in BANNER.finditer(span)}
            all_banners |= banners
            foreign = [b.decode() for b in banners if b != want_banner]
            if foreign:
                where = "slice %d" % idx if idx is not None else "the image"
                fail("%s %s has CBIOS banner %s, not RomWBW %s - booting it "
                     "would print 'HBIOS/CBIOS Version Mismatch'"
                     % (d["filename"], where, ", ".join(sorted(foreign)), ver))
                bad_here = True

        # Independent claims are checked independently. Each of these used to
        # `continue` on failure, so an image with two wrong claims reported
        # only the first and a second run was needed to find the rest.
        claimed = d.get("cbios")
        actual = sorted(b.decode() for b in all_banners)
        if claimed and claimed not in actual:
            fail("%s catalog claims cbios %r but the image has %r"
                 % (d["filename"], claimed, actual))
            bad_here = True
        if not claimed and actual:
            fail("%s catalog claims no CBIOS but the image has %r"
                 % (d["filename"], actual))
            bad_here = True

        boot = data[base: base + BOOT_TRACK_BYTES]
        bootable = len(set(boot)) > 1
        if bootable != d["bootable"]:
            fail("%s catalog says bootable=%s, boot track says %s"
                 % (d["filename"], d["bootable"], bootable))
            bad_here = True

        names = directory_names(data, base)
        has_utils = all(u in names for u in ("w8.com", "r8.com"))
        if d["host_transfer"] != has_utils:
            fail("%s catalog says host_transfer=%s but the directory %s "
                 "w8.com and r8.com"
                 % (d["filename"], d["host_transfer"],
                    "has" if has_utils else "does not have"))
            bad_here = True
        if d["host_transfer"] and has_utils:
            # Scoped to the w8.com actually on the disk, not to the whole
            # image: a 51MB image contains the three bytes 06 e9 cf somewhere
            # by chance, so an image-wide search passes on a w8.com that has
            # lost the interlock entirely.
            w8 = extract_file(data, base, "w8.com")
            if w8 is None:
                fail("%s: w8.com is in the directory but its data could not be "
                     "read - refusing to certify the interlock" % d["filename"])
                bad_here = True
            elif W8_INTERLOCK not in w8:
                fail("%s carries a w8.com with no HBF_HOST_CAPS interlock "
                     "(06 e9 cf) - it would hand an old emulator an unchecked "
                     "host path" % d["filename"])
                bad_here = True
        if not bad_here:
            ok("%s  %s  %s%s"
               % (d["filename"], "bootable" if d["bootable"] else "data-only",
                  d.get("cbios") or "no CBIOS banner",
                  "  +w8/r8" if d["host_transfer"] else ""))

    # Walk the OTHER way too. Until now nothing checked that the directory
    # holds only what the catalog describes, and publish_release.sh uploads
    # the whole directory to a tag it declares immutable - so a stale artifact
    # from an earlier build shipped forever, described by nothing.
    described = {e["filename"] for e in cat["roms"] + cat["disks"]}
    expected_extra = {
        os.path.basename(cat_path),
        os.path.basename(cat_path).replace("catalog-", "disks-").replace(".json", ".xml"),
    }
    try:
        present = {f for f in os.listdir(adir)
                   if os.path.isfile(os.path.join(adir, f))}
    except OSError as e:
        fail("cannot list %s: %s" % (adir, e))
        return not _fails
    stray = sorted(present - described - expected_extra)
    for f in stray:
        fail("%s is in the asset directory but no catalog entry names it - it "
             "would be published to an immutable tag and could never be "
             "removed" % f)
    return not _fails


def directory_names(data, base):
    names = []
    start = base + BOOT_TRACK_BYTES
    for i in range(1024):
        e = data[start + i * 32: start + (i + 1) * 32]
        if len(e) < 32 or e[0] != 0x00:
            continue
        nm = bytes(b & 0x7F for b in e[1:9]).decode("ascii", "replace").strip()
        ex = bytes(b & 0x7F for b in e[9:12]).decode("ascii", "replace").strip()
        if nm:
            names.append((nm + "." + ex if ex else nm).lower())
    return names


def verify_index(idx_path, build_dir):
    del _fails[:]
    idx = json.load(open(idx_path))
    print("index %s  interface %s  %d version(s)"
          % (os.path.basename(idx_path), idx["interface"], len(idx["romwbw_versions"])))
    defaults = [e for e in idx["romwbw_versions"] if e.get("default")]
    if len(defaults) != 1:
        fail("index names %d default RomWBW versions, expected exactly 1" % len(defaults))
    for e in idx["romwbw_versions"]:
        cp = os.path.join(build_dir, e["release_tag"],
                          os.path.basename(e["catalog_url"]))
        if not os.path.exists(cp):
            fail("index points at %s but it is not built" % os.path.basename(cp))
            continue
        if os.path.getsize(cp) != e["catalog_size"]:
            fail("%s size disagrees with the index" % os.path.basename(cp))
            continue
        if sha256(cp) != e["catalog_sha256"]:
            fail("%s sha256 disagrees with the index" % os.path.basename(cp))
            continue
        cat = json.load(open(cp))
        if cat["generation"] != e["generation"]:
            fail("%s generation %s disagrees with the index (%s)"
                 % (os.path.basename(cp), cat["generation"], e["generation"]))
            continue
        if cat["romwbw_version"] != e["romwbw_version"]:
            fail("%s is for RomWBW %s but the index files it under %s"
                 % (os.path.basename(cp), cat["romwbw_version"], e["romwbw_version"]))
            continue
        # These were printed as though they had been checked. They had not.
        if e["rom_count"] != len(cat["roms"]) or e["disk_count"] != len(cat["disks"]):
            fail("%s index says %d roms / %d disks, the catalog has %d / %d"
                 % (e["romwbw_version"], e["rom_count"], e["disk_count"],
                    len(cat["roms"]), len(cat["disks"])))
            continue
        if e["hbios"] != cat["hbios"]:
            fail("%s index hbios block disagrees with the catalog it points at"
                 % e["romwbw_version"])
            continue
        if not e["catalog_url"].startswith(cat["base_url"]):
            fail("%s index catalog_url is not under the catalog's own base_url"
                 % e["romwbw_version"])
            continue
        xml = os.path.join(build_dir, e["release_tag"],
                           os.path.basename(e["disks_xml_url"]))
        if not os.path.exists(xml):
            fail("%s index advertises %s but it is not built"
                 % (e["romwbw_version"], os.path.basename(xml)))
            continue
        ok("%s -> %s  generation %d  %d roms  %d disks"
           % (e["romwbw_version"], os.path.basename(cp), e["generation"],
              e["rom_count"], e["disk_count"]))
    return not _fails


def main():
    args = sys.argv[1:]
    if args[:1] == ["--index"]:
        good = verify_index(args[1], args[2])
    else:
        good = verify_catalog(args[0], args[1])
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
