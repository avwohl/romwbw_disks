# romwbw_disks

**Under construction.** Nothing here is wired into a shipping client yet. The
artifacts are built and published so the clients can be changed next; until
they are, every released app still fetches its disks from the old location.

ROM images and CP/M disk images for the RomWBW-based emulator clients, served
from a two-level catalog:

    interface version (v0)  ->  RomWBW version (3.5.1, 3.6.0)  ->  ROMs + disks

The entry point is one small, stable URL — `index-v0.json`, alone on the
floating `catalog-v0` tag, which is cut last, after the assets it points at:

    https://github.com/avwohl/romwbw_disks/releases/download/catalog-v0/index-v0.json

A client fetches that, offers the RomWBW versions it finds, and then fetches
that version's catalog and its assets. Adding a RomWBW release, a ROM or a disk
image is a release in this repo — not a new build of four clients.

## The clients

- [ioscpm](https://github.com/avwohl/ioscpm) — iOS and macOS
- [cpmdroid](https://github.com/avwohl/cpmdroid) — Android
- [z80cpmw](https://github.com/avwohl/z80cpmw) — Windows
- [romwbw_emu](https://github.com/avwohl/romwbw_emu) — the emulator core, Linux/macOS/WASM
- [cpmemu](https://github.com/avwohl/cpmemu) — the `qkz80` Z80 CPU core underneath it

## Why this repo exists

We do not just redistribute RomWBW. We build part of the ROM: bank 0 of every
emulator ROM is our own HBIOS proxy, which turns HBIOS calls into emulator port
I/O instead of hardware access. Banks 1–15 are the real thing, lifted verbatim
from an upstream RomWBW release.

That makes the ROM and the disk images a matched pair. RomWBW's CBIOS lives in
the boot slice of each bootable disk image and checks itself against what the
ROM's HBIOS reports; when they disagree the guest prints

    *** WARNING: HBIOS/CBIOS Version Mismatch ***

at boot. So "which RomWBW release" is a property of the artifacts, and every
artifact here says which one it is, in its filename and in the catalog.

Until now there was **one** version string: a GitHub release tag compiled into
each client, currently `v1.4.12`, pointing at the `avwohl/ioscpm` release area.
That single string was doing three jobs — naming the disk images, naming the
host-transfer ABI generation inside them, and implying which RomWBW release the
client's bundled ROM matched. It had no way to say "RomWBW 3.5.1 *or* 3.6.0",
and publishing a disk image meant releasing all four clients with no real
change in any of them.

(The disks living in the iOS repo is not a design. `ioscpm` v1.0 shipped
`disks.xml` as a release asset on 2025-12-15, two days before `romwbw_emu` had
a tag at all; every later port pointed at that URL rather than duplicating
200 MB, and it hardened into a rule.)

## What is published

One immutable release tag per RomWBW version, plus one mutable tag for the
index.

| Tag | Mutable? | Contents |
|---|---|---|
| `catalog-v0` | yes, rewritten when a version is added | `index-v0.json` only, a few KB |
| `v0-romwbw-3.5.1` | **no** | 2 ROMs, 20 disk images, catalog, legacy XML — 202 MiB |
| `v0-romwbw-3.6.0` | **no** | 2 ROMs, 24 disk images, catalog, legacy XML — 234 MiB |

The thing that moves is tiny; the things clients cache never move. Every asset
carries both versions in its name — `hd1k_combo-v0-3.5.1.img`,
`emu_avw-v0-3.6.0.rom` — so two RomWBW generations can sit in one flat download
directory without colliding.

### ROMs

| id | Bank 0 | Banks 1–15 |
|---|---|---|
| `emu_avw` | `src/emu_hbios.asm` | upstream `Binary/SBC_simh_std.rom` |
| `emu_rcz80` | `src/emu_hbios.asm` | upstream `Binary/RCZ80_std.rom` |

### Disks

Every image starts as the stock one from that RomWBW release's `Package.zip`.
The only thing this repo adds is `W8.COM` and `R8.COM` — the host file transfer
pair — and only on `hd1k_combo` slice 0, which is exactly what every shipped
client already has. The built combo differs from stock upstream by 8,234 bytes:
those two files and their two directory entries, nothing else.

`hd1k_blank.img` is not published; an empty formatted disk is a build input,
not something to offer.

RomWBW 3.6.0 drops `hd1k_ws4.img` (its combo's sixth slice is `wp`) and adds
`hd1k_cobol`, `hd1k_dos65`, `hd1k_infocom`, `hd1k_msx` and `hd1k_wp`. It also
made every published image bootable — under 3.5.1 eleven of the twenty ship
with a boot track that was never written, left at the CP/M fill byte `0xE5`.

## Building

Needs `um80` and `ul80` (`pip install um80`), `cpmtools`, `python3`, `curl`,
`unzip`.

```sh
tools/build_all.sh              # every RomWBW version
tools/build_all.sh 3.5.1        # just one
```

That assembles `w8.com`/`r8.com`, fetches the upstream `Package.zip` (pinned by
sha256), builds the ROMs, assembles the disk set, generates the catalogs from
the artifacts it just produced, and verifies the result.

Every size and hash in the published catalog is computed from the file that
gets uploaded. Nothing is transcribed. The catalog this replaces was
hand-edited, hashes included.

**The build is reproducible.** A clean rebuild produces all 48 artifacts
byte-identical. More usefully, `emu_avw-v0-3.5.1.rom` hashes to
`c7abc580b3285a33e439c0d6724a9d64dd3e93733a4fc2c1b80b0bfd91f9c580` — the same
bytes as the `emu_avw.rom` bundled in ioscpm, cpmdroid, z80cpmw and romwbw_emu
today. The rebuilt `w8.com` and `r8.com` are likewise byte-identical to the
copies inside the currently shipped `hd1k_combo.img`. This repo reproduces what
is already in users' hands before it changes anything.

### Proven by running them, not just hashing them

`tools/boot_test.sh` drives the real emulator against the built artifacts. On a
`romwbw_emu` pinned to 3.5.1 it asserts, and currently passes:

- the 3.5.1 ROM and combo boot to a CP/M prompt printing `CBIOS v3.5.1 [WBW]`,
  with no version-mismatch warning
- a 3.6.0 disk on that 3.5.1 ROM **does** print
  `*** WARNING: HBIOS/CBIOS Version Mismatch ***` — the guard firing is the
  pass condition
- the 3.6.0 ROM is refused outright, with
  `ROM is built for RomWBW v3.6.0, but this emulator is pinned to v3.5.1`

`R8` and `W8` were also round-tripped off the published combo: a 39-byte host
file imported into CP/M and exported back came out byte-identical.

The script skips rather than fails when no emulator binary is present, since a
machine that can build these is not necessarily one that can run them.

## Layout

```
src/        Z80 sources: w8.asm, r8.asm, emu_hbios.asm, emu_rom.asm
tools/      the build and verify pipeline, plus cpm_disk.py and diskdefs
versions/   one directory per RomWBW release: version, roms, disks, generation
catalog/    the generated catalogs, committed so changes show up in a diff
build/      output (gitignored)
```

The RomWBW version is not written in the assembly. `tools/build_rom.sh`
generates `romwbw_ver.inc` from `versions/<ver>/version.json`, and
`emu_hbios.asm` includes it. In `romwbw_emu` those were two hand-copied
`db 035h` pairs kept in step by a separate verify script, because um80 cannot
`#include` a C header.

## Documentation

- [docs/INTERFACE_V0.md](docs/INTERFACE_V0.md) — what `v0` promises, and when it
  would become `v1`
- [docs/CATALOG_SCHEMA.md](docs/CATALOG_SCHEMA.md) — the JSON, field by field
- [docs/ROMWBW_VERSIONS.md](docs/ROMWBW_VERSIONS.md) — 3.5.1 vs 3.6.0, and how
  to add the next one
- [docs/CLIENT_MIGRATION.md](docs/CLIENT_MIGRATION.md) — what each client has to
  change, including the one blocker
- [docs/RELEASING.md](docs/RELEASING.md) — building and publishing
- [docs/FINDINGS.md](docs/FINDINGS.md) — what was measured about the existing
  system, and what is still unknown

## The blocker, stated plainly

A client can *fetch* both RomWBW versions today. It cannot *run* both.

`emu_validate_rom_hcb` in `romwbw_emu/src/emu_init.cc:52-60` compares the
loaded ROM's HBIOS Configuration Block against the compile-time
`ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` from `src/romwbw_pin.h` and
refuses the load on a mismatch. A binary pinned to 3.5.1 physically cannot load
a 3.6.0 ROM.

So RomWBW 3.6.0 is published here as **preview**. Until `romwbw_emu` makes that
pin runtime state read from the loaded ROM, a client should filter the index
down to the version it was built for — which is why every index entry carries
`hbios.ver_byte` and `hbios.upd_byte`, so it can filter without downloading
anything. [docs/CLIENT_MIGRATION.md](docs/CLIENT_MIGRATION.md) lists what that
change touches.

Nobody has yet diffed RomWBW 3.6.0's HBIOS implementation against the HBIOS
functions the emulator core actually implements. Both
`romwbw_emu/src/romwbw_pin.h:22-26` and `romwbw_emu/DOWNSTREAM.md:424-430` list
that as required work and it is still open. Both call it the `proto.asm` diff,
but RomWBW 3.6.0 ships no `Source/HBIOS/proto.asm` — the files that carry that
information are `Source/HBIOS/hbios.asm` and `Source/Doc/SystemGuide.md`. Until
it is done, "supports 3.6.0" means the ROM and disks are built and internally
consistent — not that the emulator has been checked against them.

## Licence

GPL-3.0-or-later. RomWBW is GPLv3 and the ROM images here contain unmodified
RomWBW code in banks 1–15. Upstream:
[wwarthen/RomWBW](https://github.com/wwarthen/RomWBW).

Some published disk images carry abandonware or mixed-licence software; each
catalog entry states what it believes it is under in its `license` field.
