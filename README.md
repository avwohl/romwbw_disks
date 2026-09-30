# romwbw_disks

ROM images and CP/M disk images for the RomWBW-based emulator clients, served
from a two-level catalog:

    interface version (v0)  ->  RomWBW version  ->  ROMs + disks

The entry point is one small, stable URL — `index-v0.json`, fetched through
`releases/latest/download/`, which names no tag at all:

    https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json

GitHub resolves that to whichever release carries the Latest flag, so where the
index lives belongs to this repository and can move with no client release. It
sits on `catalog-v0` today. It was addressed as
`releases/download/catalog-v0/index-v0.json` until 29635dd, and clients built
before that still ask for the tag by name — so `catalog-v0` stays alive for as
long as any of them are in use.

A client fetches the index, offers the RomWBW versions it finds, then fetches
that version's catalog and its assets. Each client compiles in this one URL and
nothing else, so a new ROM, disk image or help topic reaches an installed app
without any of them being rebuilt. Adding a RomWBW release, a ROM or a disk
image is a release in this repo — not a new build of four clients.

Every client and the emulator core now boot whatever release the index lists;
`tools/boot_test.sh` is the release gate. See [docs/STATUS.md](docs/STATUS.md).

## The clients

- [ioscpm](https://github.com/avwohl/ioscpm) — iOS and macOS
- [cpmdroid](https://github.com/avwohl/cpmdroid) — Android
- [z80cpmw](https://github.com/avwohl/z80cpmw) — Windows
- [romwbw_emu](https://github.com/avwohl/romwbw_emu) — the emulator core, Linux/macOS/WASM, whose `tools/romwbw-get` is the reference client

[cpmemu](https://github.com/avwohl/cpmemu) supplies the `qkz80` CPU core
underneath them; it reads no catalog.

## What is published

One immutable release tag per RomWBW version (`v0-romwbw-<ver>`), plus two
mutable tags: `catalog-v0` for the index and `help-v0` for the in-app help
topics. Bank 0 of every ROM is our own HBIOS proxy; banks 1–15 are stock
RomWBW. The tags, ROMs and disk images are described in
[docs/ARTIFACTS.md](docs/ARTIFACTS.md).

## Building

Needs `um80` and `ul80` (`pip install um80`), `cpmtools`, `python3`, `curl` and
`unzip`.

```sh
tools/build_all.sh              # every RomWBW version
tools/build_all.sh 3.5.1        # just one
```

The build is reproducible, and `tools/boot_test.sh` boots every release before
the release enters the index. Details and the source layout are in
[docs/BUILDING.md](docs/BUILDING.md).

## Documentation

- [docs/ARTIFACTS.md](docs/ARTIFACTS.md) — why this repo builds part of the ROM,
  and the tags, ROMs and disk images published
- [docs/BUILDING.md](docs/BUILDING.md) — the build, the boot test, and the
  source layout
- [docs/STATUS.md](docs/STATUS.md) — the state of the published releases and
  of the boot testing
- [docs/INTERFACE_V0.md](docs/INTERFACE_V0.md) — what `v0` promises, and when it
  would become `v1`
- [docs/CATALOG_SCHEMA.md](docs/CATALOG_SCHEMA.md) — the JSON, field by field
- [docs/ROMWBW_VERSIONS.md](docs/ROMWBW_VERSIONS.md) — 3.5.1 vs 3.6.0, and how
  to add the next one
- [docs/CLIENT_MIGRATION.md](docs/CLIENT_MIGRATION.md) — what each client had to
  change; all three were migrated on 2026-09-05
- [docs/RELEASING.md](docs/RELEASING.md) — building and publishing
- [docs/FINDINGS.md](docs/FINDINGS.md) — what was measured about the existing
  system, and what is still unknown

## Licence

GPL-3.0-or-later. RomWBW is GPLv3 and the ROM images here contain unmodified
RomWBW code in banks 1–15. Upstream:
[wwarthen/RomWBW](https://github.com/wwarthen/RomWBW).

Some published disk images carry abandonware or mixed-licence software; each
catalog entry states what it believes it is under in its `license` field.
