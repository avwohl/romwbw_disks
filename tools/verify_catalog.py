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

fails = []


def fail(msg):
    fails.append(msg)
    print("  FAIL  %s" % msg)


def ok(msg):
    print("  ok    %s" % msg)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


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
    cat = json.load(open(cat_path))
    ver = cat["romwbw_version"]
    hb = cat["hbios"]
    want_hcb = bytes((0x57, 0xA8, (hb["major"] << 4) | hb["minor"],
                      (hb["update"] << 4) | hb["patch"]))
    want_banner = ("CBIOS v%s [WBW]" % ver).encode()

    print("catalog %s  interface %s  RomWBW %s  generation %s"
          % (os.path.basename(cat_path), cat["interface"], ver, cat.get("generation")))

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
        base = COMBO_PREFIX_BYTES if d["format"] == "hd1k_combo" else 0
        span = data[base: base + SLICE_BYTES] if d["format"] == "hd1k_combo" else data

        banners = {m.group(0) for m in BANNER.finditer(span)}
        bad = [b.decode() for b in banners if b != want_banner]
        if bad:
            fail("%s CBIOS banner %s does not match RomWBW %s - would print "
                 "'HBIOS/CBIOS Version Mismatch' at boot"
                 % (d["filename"], ", ".join(sorted(bad)), ver))
            continue
        claimed = d.get("cbios")
        actual = sorted(b.decode() for b in banners)
        if claimed and claimed not in actual:
            fail("%s catalog claims cbios %r but the slice has %r"
                 % (d["filename"], claimed, actual))
            continue
        if not claimed and actual:
            fail("%s catalog claims no CBIOS but the slice has %r" % (d["filename"], actual))
            continue

        boot = data[base: base + BOOT_TRACK_BYTES]
        bootable = len(set(boot)) > 1
        if bootable != d["bootable"]:
            fail("%s catalog says bootable=%s, boot track says %s"
                 % (d["filename"], d["bootable"], bootable))
            continue

        if d["host_transfer"]:
            names = directory_names(data, base)
            missing = [u for u in ("w8.com", "r8.com") if u not in names]
            if missing:
                fail("%s claims host_transfer but is missing %s"
                     % (d["filename"], ", ".join(missing)))
                continue
            if W8_INTERLOCK not in data:
                fail("%s carries a w8.com with no HBF_HOST_CAPS interlock "
                     "(06 e9 cf) - it would hand an old emulator an unchecked "
                     "host path" % d["filename"])
                continue
        ok("%s  %s  %s%s"
           % (d["filename"], "bootable" if d["bootable"] else "data-only",
              d.get("cbios") or "no CBIOS banner",
              "  +w8/r8" if d["host_transfer"] else ""))
    return not fails


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
        ok("%s -> %s  generation %d  %d roms  %d disks"
           % (e["romwbw_version"], os.path.basename(cp), e["generation"],
              e["rom_count"], e["disk_count"]))
    return not fails


def main():
    args = sys.argv[1:]
    if args[:1] == ["--index"]:
        good = verify_index(args[1], args[2])
    else:
        good = verify_catalog(args[0], args[1])
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
