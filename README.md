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

That last sentence was an aspiration until 2026-09-17. Every client, and the
emulator core underneath them, carried a compile-time allowlist of RomWBW
releases, so publishing a new one here reached nobody until Windows, macOS,
iOS, Android and Linux had all been rebuilt. `romwbw_emu` v1.44 deleted the
core's list, and all three GUI clients dropped theirs the same day. What stands
in its place is `tools/boot_test.sh` and the rule that a release enters
`index-v0.json` only after it passes — see
[docs/INTERFACE_V0.md](docs/INTERFACE_V0.md).

## The clients

- [ioscpm](https://github.com/avwohl/ioscpm) — iOS and macOS
- [cpmdroid](https://github.com/avwohl/cpmdroid) — Android
- [z80cpmw](https://github.com/avwohl/z80cpmw) — Windows
- [romwbw_emu](https://github.com/avwohl/romwbw_emu) — the emulator core, Linux/macOS/WASM, whose `tools/romwbw-get` is the reference client

[cpmemu](https://github.com/avwohl/cpmemu) supplies the `qkz80` CPU core
underneath them; it reads no catalog.

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

Before this, one GitHub release tag was compiled into each client and did three
jobs at once: naming the disk images, naming the host-transfer ABI generation
inside them, and implying which RomWBW release the client's ROM matched. It had
no way to say "3.5.1 *or* 3.6.0", and publishing a disk image meant releasing
all four clients with no real change in any of them.

## What is published

One immutable release tag per RomWBW version, plus two mutable tags.

| Tag | Mutable? | Contents |
|---|---|---|
| `catalog-v0` | yes, rewritten when a version is added or a help topic changes | `index-v0.json` only, a few KB |
| `help-v0` | yes, re-cut when a topic changes | the in-app help topics, named by the index's `help.base_url` |
| `v0-romwbw-<ver>` | **no** | that release's ROMs, disk images, catalog and legacy XML |

The things that move are tiny; the things clients cache never move. Every asset
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
pair — and only on `hd1k_combo` slice 0. The built combo differs from stock
upstream by 8,234 bytes: those two files and their two directory entries,
nothing else.

`hd1k_blank.img` is not published; an empty formatted disk is a build input, not
something to offer.

RomWBW 3.6.0 drops `hd1k_ws4.img` (its combo's sixth slice is `wp`) and adds
`hd1k_cobol`, `hd1k_dos65`, `hd1k_infocom`, `hd1k_msx` and `hd1k_wp`. It also
made every published image bootable — under 3.5.1 eleven of the twenty ship with
a boot track that was never written, left at the CP/M fill byte `0xE5`.

## Building

Needs `um80` and `ul80` (`pip install um80`), `cpmtools`, `python3`, `curl` and
`unzip`. Downloads and extracts under `$ROMWBW_CACHE` (default `$HOME/esrc`),
deliberately outside the repo and shared between versions. `fetch_romwbw.sh`
pulls only what a build needs out of each archive — the two stock ROMs and the
generic hd1k images — because the full unpack would be about a gigabyte per
release; the ~199 MB zip is kept beside it and re-checked against the sha256 in
`versions/<ver>/version.json`.

```sh
tools/build_all.sh              # every RomWBW version
tools/build_all.sh 3.5.1        # just one
```

That assembles `w8.com`/`r8.com`, fetches the upstream `Package.zip` (pinned by
sha256), builds the ROMs, assembles the disk set, generates the catalogs from
the artifacts it just produced, and verifies the result. Every size and hash in
the published catalog is computed from the file that gets uploaded; nothing is
transcribed.

**The build is reproducible.** A clean rebuild produces all 48 artifacts
byte-identical: `emu_avw-v0-3.5.1.rom` hashes to
`4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258`, and the
rebuilt `w8.com` and `r8.com` are byte-identical to the copies inside the
published `hd1k_combo.img`. So a rebuild reproduces what is already published
before it changes anything.

### Proven by running them, not just hashing them

`tools/boot_test.sh` drives the real emulator against the built artifacts. It
tests **every** published release, unconditionally: since `romwbw_emu` v1.44
the emulator refuses no release, so there is nothing to ask it and nothing it
may legitimately decline. For each release it asserts — and currently passes:

    === RomWBW v3.5.1 ===
      ok    boots and prints CBIOS v3.5.1 [WBW]
      ok    reaches the CP/M prompt
      ok    no version-mismatch warning, as expected for a matched pair
      ok    the emulator reports v3.5.1, read from the ROM
      ok    a v3.6.0 disk on a v3.5.1 ROM warns, as it must
      ok    R8/W8 round-trip a file byte-identically

The mismatch warning firing is a pass condition, not a failure: it is now the
only thing enforcing the ROM/disk pairing. The `R8`/`W8` round trip exercises the
private `0xE1`–`0xEA` host block that upstream RomWBW knows nothing about. There
is no case in which a release failing to boot is a pass — the script used to
expect a refusal by name for a release the emulator had not been built against,
and `romwbw_emu` v1.44 removed the refusal. It skips rather than fails when no
emulator binary is present, since a machine that can build these is not
necessarily one that can run them.

**This script is the release gate.** Publishing a release into `index-v0.json`
is the assertion that it passed here — see
[docs/INTERFACE_V0.md](docs/INTERFACE_V0.md) and
[docs/RELEASING.md](docs/RELEASING.md) §5.

## Status

Both published releases are `stable`, and the index flags one of them
`default: true` — a fresh client lands there.

A client offers every release the index lists. It does not screen them on its
core's behalf: the emulator reads the RomWBW version out of the loaded ROM
(`romwbw_emu` v1.39 onward) and since v1.44 refuses no release at all, so one
binary boots whatever is published. The `hbios.ver_byte` and `hbios.upd_byte`
in every entry keep the job they always had — they pair a ROM with the disk
images that match it, which is the axis the guest's own
`HBIOS/CBIOS Version Mismatch` warning is about. A client that still bundles
one ROM uses them for exactly that.

Binaries built before 2026-09-17 filter the index by release and see only the
version they were built for; that is a property of those builds, not of the
catalog, and rebuilding is the whole of the fix.

RomWBW 3.6.0 has been booted from the images published here.
`tools/boot_test.sh` asserts the CP/M 2.2 boot, the `CBIOS [WBW]` banner, the
prompt, the release the emulator reports back from the ROM, a mismatched pair
warning in both directions, and the `R8`/`W8` round trip. Checked once by hand
on 2026-09-05 and re-run by no script: banked CP/M 3, ZPM3, Z3PLUS, ZSDOS and
NZCOM all boot, and the boot loader prints `NV Switches Found`, so the NVRAM
checksum seed agrees with the ROM's own SYSCONF.

What this does **not** close is the source-level question. Nobody has read
3.6.0's `Source/HBIOS/hbios.asm` against the functions the emulator's dispatcher
implements, and booting six operating systems exercises much of that surface
without enumerating it. "Supports 3.6.0" means the release has been run, not
that the dispatcher has been audited against it —
[docs/FINDINGS.md](docs/FINDINGS.md) keeps that item open.

## Layout

```
src/        Z80 sources: w8.asm, r8.asm, emu_hbios.asm, emu_rom.asm
tools/      the build and verify pipeline, plus diskdefs
versions/   one directory per RomWBW release: version, roms, disks, generation
catalog/    the generated catalogs, committed so changes show up in a diff
help/       the in-app help topics, published on the help-v0 tag
docs/       the documents listed below
build/      output (gitignored)
```

The RomWBW version is not written in the assembly. `tools/build_rom.sh`
generates `romwbw_ver.inc` from `versions/<ver>/version.json`, and
`emu_hbios.asm` includes it — where `romwbw_emu` still keeps two hand-copied
`db 035h` pairs, because um80 cannot `#include` a C header.

## Documentation

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
