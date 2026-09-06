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
`4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258` — the same
bytes as the `emu_avw.rom` bundled in ioscpm, cpmdroid, z80cpmw and romwbw_emu
today. The rebuilt `w8.com` and `r8.com` are likewise byte-identical to the
copies inside the currently shipped `hd1k_combo.img`. This repo reproduces what
is already in users' hands before it changes anything.

### Proven by running them, not just hashing them

`tools/boot_test.sh` drives the real emulator against the built artifacts. It
asks the binary which RomWBW releases it can run and holds it to that answer,
so the same script is correct against an emulator with the old compile-time pin
and against one with the runtime version. For each release the emulator can
run, it asserts — and currently passes:

- the ROM and combo boot to a CP/M prompt printing `CBIOS v<ver> [WBW]`, with
  no version-mismatch warning
- the emulator reports that release, read from the ROM — skipped against a
  pinned build, which never read one
- a disk from *another* release on that ROM **does** print
  `*** WARNING: HBIOS/CBIOS Version Mismatch ***` — the guard firing is the
  pass condition, and it is now the only thing enforcing the ROM/disk pairing
- `R8` and `W8` round-trip a file byte-identically, which exercises the private
  `0xE1`–`0xEA` host block that upstream RomWBW knows nothing about

For a release the emulator *cannot* run, the refusal by name is the pass.

Against `romwbw_emu` v1.39 the run ends:

    One emulator binary booted v3.5.1 v3.6.0 - 2 published releases.

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
  change, now that the emulator blocker is cleared
- [docs/RELEASING.md](docs/RELEASING.md) — building and publishing
- [docs/FINDINGS.md](docs/FINDINGS.md) — what was measured about the existing
  system, and what is still unknown

## The blocker: cleared in the core, still live in the clients

A client could *fetch* both RomWBW versions and run only one. That was the one
thing this repository's design could not fix on its own, and it is now fixed —
upstream, in `romwbw_emu`, not here.

`emu_validate_rom_hcb` compared a loaded ROM's HBIOS Configuration Block
against the compile-time `ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` and
refused the load on a mismatch, so a binary pinned to 3.5.1 physically could
not load a 3.6.0 ROM. **The version is now read out of the loaded ROM at run
time** (`romwbw_emu` v1.39), and one binary boots every release in that core's
`ROMWBW_SUPPORTED_RELEASES` — today both of ours. Five sites reported a version
to the guest and all five now derive it from the ROM: `HBF_SYSVER`, the NVRAM
checksum seed, the HBIOS ident block, the CBIOS page-zero stamp at
`0x42`/`0x43`, and the load-time check itself.

`tools/boot_test.sh` proves it against these artifacts, and still passes
against an emulator built before the change — it asks the binary which releases
it can run and holds it to the answer. Abridged, with the v3.6.0 block folded
away:

    can run RomWBW: v3.5.1 v3.6.0

    === RomWBW v3.5.1 ===
      ok    boots and prints CBIOS v3.5.1 [WBW]
      ok    reaches the CP/M prompt
      ok    no version-mismatch warning, as expected for a matched pair
      ok    the emulator reports v3.5.1, read from the ROM
      ok    a v3.6.0 disk on a v3.5.1 ROM warns, as it must
      ok    R8/W8 round-trip a file byte-identically

    One emulator binary booted v3.5.1 v3.6.0 - 2 published releases.

**3.6.0 is `stable` in the published index as of 2026-09-05**, promoted on the
strength of the emulator booting it rather than of a client shipping it. Be
clear about what that does and does not mean: no *released client* carries the
v1.39 core — iOS, Android and Windows all ship a binary built before it — so a
shipped client still cannot load a 3.6.0 ROM. It does not have to be told not
to. It filters the index down to the release its own core can run, using the
`hbios.ver_byte` and `hbios.upd_byte` in every entry, and 3.6.0 simply does not
survive that filter on a pre-v1.39 build. That is what those two bytes are for,
and why promoting a release a shipped client cannot boot is safe rather than a
trap. [docs/CLIENT_MIGRATION.md](docs/CLIENT_MIGRATION.md)
lists what each client has to change.

The published `versions/3.6.0/version.json` note still describes the old
refusal, naming `emu_init.cc:52-60` and `ROMWBW_PIN_STR`. Its *conclusion* is
still true — no released client can load a 3.6.0 ROM — but its explanation is
stale. It is not corrected in place: that catalog is published on the immutable
`v0-romwbw-3.6.0` tag, and this repository never rewrites a published asset.
It gets corrected the next time that version's assets are legitimately re-cut.

### And 3.6.0 has now actually been run

Under the runtime-version core, RomWBW 3.6.0 has been booted from the images
published here — which it never had been. Two different kinds of evidence, and
it is worth keeping them apart.

`tools/boot_test.sh` asserts on every run, for every release the emulator can
run: the CP/M 2.2 boot, the `CBIOS v3.6.0 [WBW]` banner, the CP/M prompt, the
release the emulator reports back from the ROM, a mismatched pair warning in
both directions, and an `R8`/`W8` round trip that comes back byte-identical —
which exercises the private `0xE1`–`0xEA` host block that upstream knows
nothing about.

Checked once by hand on 2026-09-05, and re-run by no script: banked CP/M 3,
ZPM3, Z3PLUS, ZSDOS and NZCOM all boot, and the boot loader prints
`NV Switches Found`, so the NVRAM checksum seed agrees with the ROM's own
SYSCONF.

What this does **not** close is the source-level question. Nobody has read
3.6.0's `Source/HBIOS/hbios.asm` against the functions the emulator's
dispatcher implements, and booting six operating systems exercises much of that
surface without enumerating it. "Supports 3.6.0" now means the release has been
run, not that the dispatcher has been audited against it —
[docs/FINDINGS.md](docs/FINDINGS.md) keeps that item open.

Both `romwbw_emu/src/romwbw_pin.h` and `romwbw_emu/DOWNSTREAM.md` used to list
a `proto.asm` diff as required work before adopting a release. There is no such
file: RomWBW ships no `Source/HBIOS/proto.asm` in any release — the files that
carry that information are `Source/HBIOS/hbios.asm` and
`Source/Doc/SystemGuide.md`. Both documents now describe booting the release
and exercising the host block instead, which is what was actually done.

## Licence

GPL-3.0-or-later. RomWBW is GPLv3 and the ROM images here contain unmodified
RomWBW code in banks 1–15. Upstream:
[wwarthen/RomWBW](https://github.com/wwarthen/RomWBW).

Some published disk images carry abandonware or mixed-licence software; each
catalog entry states what it believes it is under in its `license` field.
