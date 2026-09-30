# What is published, and why

Why this repository builds part of the ROM, and the release tags, ROMs and disk images published here. Back to the [README](../README.md).

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
