#!/usr/bin/env python3
"""diskinfo.py - report the facts about a built RomWBW disk image.

Usage: diskinfo.py <image> <diskdef>

Prints one JSON object.  Both tools/build_disks.sh and tools/gen_catalog.py
read it, so the catalog can never claim something the builder did not check.

What it reports and why:

  bootable      Whether the slice's boot track holds a system image.  This is
                a property of the first 16384 bytes of the slice (2 tracks x
                16 sectors x 512), NOT of any string in the image.  CP/M 3 and
                ZPM3 slices load BIOS3.SPR and carry no "CBIOS v" banner at
                all, so a banner test alone reports them as data-only and the
                catalog then tells the user something false.

  cbios         The "CBIOS v<ver> [<platform>]" banner, when there is one.
                RomWBW's CBIOS compares its own major.minor against what
                HBF_SYSVER returns and prints "HBIOS/CBIOS Version Mismatch"
                when they differ, so this string is what has to agree with the
                ROM.  Note the comparison upstream is major.minor ONLY - 3.5.0
                against 3.5.1 would not warn, 3.5.x against 3.6.x always does.

  utils         Which of w8.com / r8.com are in the slice's directory.

A "-dev.NN" banner is reported verbatim rather than normalised.  A development
snapshot has the same HCB bytes as the release it precedes, so the banner is
the only thing that can tell them apart.
"""
import json
import re
import sys

BOOT_TRACK_BYTES = 2 * 16 * 512          # 16384
SLICE_BYTES = 8 * 1024 * 1024            # 8388608
COMBO_PREFIX_BYTES = 1024 * 1024         # 1048576, the MBR prefix
DIR_ENTRIES = 1024
DIR_ENTRY_BYTES = 32

BANNER = re.compile(rb"CBIOS v([0-9][0-9A-Za-z.\-]*) \[([A-Z]+)\]")


def slice_offset(diskdef):
    """Byte offset of the slice a diskdef names."""
    if diskdef == "wbw_hd1k":
        return 0
    m = re.fullmatch(r"wbw_hd1k_(\d+)", diskdef)
    if not m:
        raise SystemExit("diskinfo: unknown diskdef %r" % diskdef)
    return COMBO_PREFIX_BYTES + int(m.group(1)) * SLICE_BYTES


def directory_names(data, base):
    """Filenames in the CP/M directory of the slice starting at `base`.

    Deliberately hand-rolled rather than shelled out to cpmls: this runs once
    per image over an already-open buffer, and it must not depend on which
    diskdefs file happens to be on the caller's path.
    """
    names = []
    start = base + BOOT_TRACK_BYTES
    for i in range(DIR_ENTRIES):
        e = data[start + i * DIR_ENTRY_BYTES: start + (i + 1) * DIR_ENTRY_BYTES]
        if len(e) < DIR_ENTRY_BYTES or e[0] != 0x00:
            # 0xE5 is a deleted entry; any other user number is a live entry
            # belonging to a user area we are not asked about.
            continue
        name = bytes(b & 0x7F for b in e[1:9]).decode("ascii", "replace").strip()
        ext = bytes(b & 0x7F for b in e[9:12]).decode("ascii", "replace").strip()
        if not name:
            continue
        full = (name + "." + ext if ext else name).lower()
        if full not in names:
            names.append(full)
    return names


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    path, diskdef = sys.argv[1], sys.argv[2]
    data = open(path, "rb").read()
    base = slice_offset(diskdef)
    if base + BOOT_TRACK_BYTES > len(data):
        raise SystemExit("diskinfo: %s is too small for diskdef %s" % (path, diskdef))

    boot = data[base: base + BOOT_TRACK_BYTES]
    fill = boot[0] if boot else 0
    # Scan the SLICE, not the whole file.  A combo holds six independent
    # boot slices; reporting a banner found anywhere in the image as though it
    # described the slice asked about is how a catalog ends up asserting that
    # a data-only slice boots.
    span = data[base: base + SLICE_BYTES] if diskdef != "wbw_hd1k" else data
    banners = sorted({m.group(0).decode() for m in BANNER.finditer(span)})
    names = directory_names(data, base)

    out = {
        "size": len(data),
        # An hd1k image that was never made bootable has its boot track left
        # at the CP/M fill byte 0xE5 - uniformly non-zero, so "any byte set"
        # calls every data disk bootable.  A real boot track is a loader plus a
        # system image and is never one repeated byte.
        "bootable": len(set(boot)) > 1,
        "cbios": banners[0] if banners else None,
        "cbios_all": banners,
        "utils": [u for u in ("w8.com", "r8.com") if u in names],
        "file_count": len(names),
        "boot_fill": ("0x%02X" % fill) if len(set(boot)) == 1 else None,
    }
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
