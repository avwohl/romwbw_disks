# RomWBW versions

This repository publishes a complete set of ROMs and disk images for each
RomWBW release it supports. A client is built for one interface version and
picks a RomWBW version out of the catalog at runtime; the two axes are
separate, and [INTERFACE_V0.md](INTERFACE_V0.md) explains why. This document
covers the other axis: which RomWBW releases exist here, exactly what differs
between them, and what supporting each one costs.

## The releases

| RomWBW | Upstream tag | Released | Status | HCB bytes | ROMs | Disks |
|---|---|---|---|---|---|---|
| 3.5.1 | `v3.5.1` | 2025-05-21 | stable (default) | `35 10` | 2 | 20 |
| 3.6.0 | `v3.6.0` | 2026-03-28 | preview | `36 00` | 2 | 24 |

`Package.zip` sha256, as pinned in `versions/<ver>/version.json`:

    3.5.1  e696ff2faf8f6420367ae3d0ad14c9daf1d7b08727b2699d005e877cc755da20
    3.6.0  bdf847d52cf6b4dd522fa81acf32e24c044ecb26f2d9ff8af72def9d6c41ffc2

"HCB bytes" are the two packed version bytes RomWBW puts at file offsets
`0x105` and `0x106` of a ROM, behind the marker `'W' 0xA8` at `0x103`/`0x104`.
High nibble is major/update, low nibble is minor/patch: 3.5.1 is `0x35 0x10`,
3.6.0 is `0x36 0x00`.

Both releases ship the same two ROMs — `emu_avw` (upstream
`Binary/SBC_simh_std.rom` in banks 1-15) and `emu_rcz80` (upstream
`Binary/RCZ80_std.rom`), 512 KB each. The ROMs and disk images total 202 MiB
(211,812,352 bytes) for 3.5.1 and 234 MiB (245,366,784 bytes) for 3.6.0; the
per-version catalog JSON and legacy XML that ship alongside them add about
19 KB and 23 KB respectively.

3.6.0 is marked `preview` and `default: false` because no released client can
load its ROM at all. That is a client-side pin, not anything about the
artifacts; see [INTERFACE_V0.md](INTERFACE_V0.md) and
[CLIENT_MIGRATION.md](CLIENT_MIGRATION.md).

## How a RomWBW version is represented here

`versions/<ver>/version.json` is the single source of truth. It carries the
version string, the release date, the status and default flag, the four HBIOS
numbers (`major`, `minor`, `update`, `patch`) together with the derived
`ver_byte`, `upd_byte` and `sysver_de`, the upstream tag and package URL, the
pinned `package_sha256`, and free-text `notes` that propagate into the
published catalog.

Three more manifests sit beside it:

| File | What it says | Who writes it |
|---|---|---|
| `roms.json` | which stock ROM each emulator ROM splices in | a human |
| `disks.json` | which upstream images to publish, their `diskdef`, and which slices get `w8.com`/`r8.com` | a human |
| `generation.json` | the cache-invalidation counter | `tools/gen_catalog.py` only |

Nothing a human writes in those files carries a size or a hash. The one hash
that appears anywhere in them is `generation.json`'s `content_sha256`, and
`tools/gen_catalog.py` computes that itself over the published filenames and
their hashes purely to decide when to advance the counter
(`tools/gen_catalog.py:88-112`) — it describes no artifact. Every size and
every sha256 in the published catalog is computed by `tools/gen_catalog.py`
from the file that will actually be uploaded.

### One version number, one place

`tools/build_rom.sh:44-50` generates `romwbw_ver.inc` from
`versions/<ver>/version.json`:

    RMV_VER	equ	035h	; (3<<4)|5
    RMV_UPD	equ	010h	; (1<<4)|0

`src/emu_hbios.asm:9` does `include romwbw_ver.inc`, and the two places that
stamp the version — the HCB at `src/emu_hbios.asm:121-122` and the proxy ident
block at `src/emu_hbios.asm:324-325`, which lands at `0xFE02` — both use
`RMV_VER`/`RMV_UPD`. One assembly source builds a ROM for any release, and the
two copies cannot drift from each other or from the catalog.

The build then re-reads the bytes it actually produced rather than trusting
the source: `tools/build_rom.sh:89-94` reads offset `0x103` back out of the
finished ROM and deletes the file if it is not `57a8` plus the expected two
bytes.

### How romwbw_emu did it, and why

In `romwbw_emu` the same two stamps were two hand-copied literal pairs:

    romwbw_emu/src/emu_hbios.asm:113-114     db 035h / db 010h   (HCB)
    romwbw_emu/src/emu_hbios.asm:316-317     db 035h / db 010h   (ident block)

A third copy lived in C, as `ROMWBW_PIN_MAJOR`/`MINOR`/`UPDATE`/`PATCH` in
`romwbw_emu/src/romwbw_pin.h:34-37`, and a fourth in
`romwbw_emu/src/romwbw_pin.h:38` as the string `"3.5.1"`. Keeping them in step
was the job of a separate script, `romwbw_emu/roms/verify_romwbw_pin.sh`,
which re-derived the expected bytes from the header and checked the built
artifacts after the fact.

That was not carelessness. The C++ emulator core needs the number as
preprocessor macros, and `um80` needs it as an assembler `equ`. `um80` cannot
`#include` a C header — there is no file format both toolchains read — so a
value used by both had to be written twice and reconciled by something
outside either language. The verify script was the reconciliation.

This repo removes the shared-value problem instead of checking it: the number
lives in JSON, which both a shell script and Python can read, and the `.inc`
the assembler consumes is generated at build time. What remains to be checked
is the built binary, not the sources.

## What changed between 3.5.1 and 3.6.0

Verified by fetching both `Package.zip` archives and diffing them.

### Version constants

`Source/ver.inc`: `RMJ`/`RMN`/`RUP`/`RTP` go from `3`/`5`/`1`/`0` to
`3`/`6`/`0`/`0`. Packed, that is `0x35 0x10` to `0x36 0x00`. `HBF_SYSVER`
returns those two bytes in `DE`: `0x3510` under 3.5.1, `0x3600` under 3.6.0.

### HBIOS API

All 124 `BF_*` function equates in `Source/HBIOS/hbios.inc` carry **identical
values** between the two releases. No function number moved, and none was
removed. Exactly one of those 124 lines differs at all, and only in its
trailing comment: `BF_SNDNOTE`'s "EACH VALUE IS QUARTER NOTE" became "EACH
VALUE IS AN EIGHTH TONE".

There is exactly one real ABI change:

    HB_IDENT .EQU HBX_XFCFNS + 14   ->   HBX_XFCFNS + 12

`HBX_XFC` is `0xFFE0` and `HBX_XFCFNS` is `0xFFF0`, so the ident pointer moved
from `0xFFFE` to `0xFFFC`. Upstream's own consumer moved with it:
`Source/HBIOS/sysconf.asm` changed `ident .EQU $FFFE` to `ident .EQU $FFFC`.

The emulator is **accidentally already compatible**. `src/emu_hbios.asm:366-367`
writes `dw HBX_LOC` at both addresses:

    	dw	HBX_LOC			; 0xFFFC: Ident pointer -> proxy start
    	dw	HBX_LOC			; 0xFFFE: HB_IDENT for RomWBW v3.5.1 and older

That duplicate was there before anyone knew about the move. The old comment
at `romwbw_emu/src/emu_hbios.asm:359` called `0xFFFE` "Reserved", which was
wrong — it was the ident pointer all along. This repo corrected the comment
and documented the constraint at `src/emu_hbios.asm:369-373`: **the duplicate
must not be removed.** Delete either word and a guest built against the other
release reads a zero and follows it.

### ROM layout

Upstream's ROMs are not all 512 KB, and that was already true in 3.5.1. Of the
47 `.rom` files in 3.6.0's `Binary/`, 38 are 512 KB, six are 384 KB,
`MSX_std.rom` is 256 KB, `RCZ80_ez512_std_64k.rom` is 65,445 bytes and
`hdiag.rom` is 1,550. 3.5.1's `Binary/` has the same shape: 36 of 44 at
512 KB, six at 384 KB, `RCZ280_zzrcc_std.rom` at 256 KB and the same
`hdiag.rom`. The two this repo splices — `SBC_simh_std.rom` and
`RCZ80_std.rom` — are 512 KB in both releases, and `tools/build_rom.sh:82`
refuses a stock ROM that is not.

3.6.0 appends new device IDs: `DIODEV_USB` `0x0F`, `DIODEV_ESPSD` `0x10`,
`DIODEV_SCSI` `0x11`, three new CIO devices (`CIODEV_DLPSER` `0x11`,
`CIODEV_TSER` `0x12`, `CIODEV_SCC` `0x13`), four new RTC devices (`RTCDEV_PC`
`0x08` through `RTCDEV_M6242` `0x0B`) and one new VDA device
(`VDADEV_XOSERA` `0x08`). Two platform IDs were **renamed without being
renumbered**: `PLT_S100` became `PLT_SZ180` and `PLT_FZ80` became `PLT_SZ80`,
still 16 and 23. `VDADEV_FV` was renamed `VDADEV_TVGA` at the same `0x07` the
same way. Three platform IDs were added: `PLT_MSX` 25, `PLT_N8PC` 26,
`PLT_RC2014` 27. None of that collides with what the emulator ROM declares —
it declares platform `0` (EMU) at `src/emu_hbios.asm:124` and no devices of
its own.

### Disk and hd1k format

`Source/Images/diskdefs` is **byte-identical** between the releases:

    sha256 697ef8a52f89401e46bd7720ec227af1351fd189fb5a23ed62acdc15755ed4c1

The hd1k slice geometry is therefore unchanged: 512-byte sectors, 16 sectors
per track, 1024 tracks, 4096-byte blocks, 1024 directory entries, 2 boot
tracks — exactly 8,388,608 bytes per slice. A combo image is a 1,048,576-byte
MBR prefix followed by six whole slices, 51,380,224 bytes. RomWBW's hd1k MBR
partition type is `0x2E`. All of that holds for both releases.

(Not to be confused with `tools/diskdefs`, which is this repo's own cpmtools
definition file. It mirrors the same geometry and adds the per-slice `offset`
definitions cpmtools needs to reach into a combo image; its own header
explains why it has to exist. It is a separate file from upstream's
`Source/Images/diskdefs` and nothing in this build reads upstream's copy,
though the `wbw_hd1k` stanza in it is the same stanza, copied from the stock
cpmtools distribution.)

What did change is how upstream builds the images. v3.6.0's `Images/Makefile`
is now `*.def`/wildcard driven and evaluates `@` directives out of each
image's `hd_<name>.txt`: `@SysImage=` names the boot-track system image, and
`@Label=` writes a CP/M volume label — trimmed or `$`-padded to 16 characters
— at byte offset 1511 (`Images/Makefile:119-127`). 3.5.1's `Makefile` has no
directive handling at all, so only the images that already carried a label
have one; in 3.6.0 every single-slice `hd1k_*.img` does. The combo is the
exception in both releases: its byte 1511 falls inside the 1 MB MBR prefix,
not a directory. Measured:

    3.5.1  hd1k_cpm22.img @1511  "CP/M 2.2$$$$$$$$"
    3.5.1  hd1k_games.img @1511  E5 E5 E5 ... (never written)
    3.6.0  hd1k_cpm22.img @1511  "CP/M 2.2$$$$$$$$"
    3.6.0  hd1k_games.img @1511  "Games$$$$$$$$$$$"

### Disk sets

Generic `hd1k_*.img` images in each `Package.zip`, from `Binary/`:

**3.5.1 — 21 images**
`aztecc bascomp blank bp combo cowgol cpm22 cpm3 fortran games hitechc
msxroms1 msxroms2 nzcom qpm tpascal ws4 z3plus z80asm zpm3 zsdos`

**3.6.0 — 25 images**
`aztecc bascomp blank bp cobol combo cowgol cpm22 cpm3 dos65 fortran games
hitechc infocom msx msxroms1 msxroms2 nzcom qpm tpascal wp z3plus z80asm zpm3
zsdos`

The delta:

| | Images |
|---|---|
| Removed in 3.6.0 | `ws4` |
| Added in 3.6.0 | `cobol`, `dos65`, `infocom`, `msx`, `wp` |

`hd1k_ws4.img` does not exist in 3.6.0. 3.6.0's `Source/Images/combo.def`
lists slice 5 as `wp` (word processing); 3.5.1 has no `combo.def` at all —
its `Images/Makefile` built the combo by concatenating a hand-written
`HD1KIMGS` list whose sixth entry was `hd1k_ws4.img`.

This repo publishes every generic image except `hd1k_blank.img`. An empty
formatted disk is a build input, not something to offer a user. That gives
**20** published disks for 3.5.1 and **24** for 3.6.0, listed in
`versions/<ver>/disks.json`.

Every image starts as the stock one from that release's `Package.zip`. The
only thing added is `W8.COM` and `R8.COM`, and only on `hd1k_combo` slice 0 —
which is exactly what every shipped client already has. Every other published
image is byte-identical to its upstream original, in both releases. Measured
on the built 3.6.0 combo against the stock upstream image: 8,234 bytes differ
across 24 runs, all of it `w8.com`, `r8.com` and their two directory entries.

### Bootability

Measured from the boot track, not from a banner: the first 16,384 bytes of the
slice (2 boot tracks x 16 sectors x 512 bytes). An image upstream never made
bootable is left at the CP/M fill byte `0xE5` throughout, so "any byte set"
would call every data disk bootable; the test is whether the boot track holds
more than one distinct byte value (`tools/diskinfo.py:100-104`).

**3.5.1 — 9 of 20 published images boot:**
`combo cpm22 zsdos zpm3 cpm3 nzcom qpm z3plus bp`

**3.5.1 — 11 are data-only:**
`games aztecc bascomp cowgol fortran hitechc tpascal z80asm ws4 msxroms1
msxroms2`

**3.6.0 — all 24 published images boot.**

The combo changed too: slice 5 is `0xE5` fill in 3.5.1 and holds a real boot
track in 3.6.0. So the 3.5.1 combo has five bootable slices out of six and the
3.6.0 combo has all six.

One trap in measuring this. CP/M 3, ZPM3 and Z3Plus slices carry **no**
`CBIOS v` banner at all — they load `BIOS3.SPR` from the file system instead —
so a banner test alone would wrongly call `hd1k_cpm3`, `hd1k_zpm3` and
`hd1k_z3plus` data-only in both releases. Verified directly: grepping the
first 16,384 bytes of each of those three 3.6.0 images for `CBIOS v` returns
nothing — as does grepping the whole image — and all three are bootable. The
per-image results are in `build/.diskinfo-<ver>.tsv` after a build.

### NVRAM

RomWBW's `NVSW_CHECKSUM` XORs the version bytes into the checksum seed
(`Source/HBIOS/hbios.asm`, `XOR RMJ << 4 | RMN` then `XOR RUP << 4 | RTP`).
The code is identical between the releases; the constants it folds in are not.
The consequence is that an NVRAM blob saved under 3.5.1 fails validation under
a 3.6.0 ROM and **silently resets to defaults** — the mismatch path in
`NVR_INIT` just calls `NVSW_DEFAULTS`: no error, no prompt.

The emulator implements the same seed at
`romwbw_emu/src/hbios_dispatch.cc:697-707`, derived from the same compile-time
macro.

For clients this is a storage-key problem, not a code problem. iOS keeps the
blob under one `UserDefaults` key, `"emulatorNvram"`
(`ioscpm/iOSCPM/Views/EmulatorViewModel.swift:199`), which has to become
per-RomWBW-version before a user can hold both releases. That is tracked in
[CLIENT_MIGRATION.md](CLIENT_MIGRATION.md).

### Toolchain

Nothing in this repo's toolchain differs between the two releases. The same
`um80`/`ul80` (`pip install um80`) assembles `src/emu_hbios.asm`,
`src/w8.asm` and `src/r8.asm`; the same `cpmtools` and the same
`tools/diskdefs` write the images; the same `build/utils/w8.com` and
`build/utils/r8.com` — byte-identical files, built once — go onto both disk
sets. The host-transfer utilities belong to the interface, not to any RomWBW
release (`tools/build_all.sh:26-28`).

`um80` is deliberately unpinned: it is a pip package, vendored nowhere, and
nothing in this tree fixes its version (`docs/CLIENT_MIGRATION.md:206-209`).
That is a known risk with history: a `um80` 0.3.42 regression miscompiled
`add a,'a'-'A'` as `add a,0`, which is why `cpmdroid` still carries a runtime
hot-patch that rewrites bytes inside every disk image it loads
(`cpmdroid/app/src/main/cpp/emu_io_android.cpp:1129-1147`). The `w8.com` this
repo builds contains the fixed sequence `fe41d8fe5bd0c620`, so that patch is
now dead code and a liability. See [CLIENT_MIGRATION.md](CLIENT_MIGRATION.md).

What upstream used to build the 3.6.0 binaries is not something this repo
measured. Banks 1-15 of every ROM and the whole of every disk image are taken
verbatim from `Package.zip`, so upstream's own toolchain does not reach this
build.

## What is not yet done

**Nobody has diffed v3.6.0's HBIOS function implementations against the HBIOS
functions the emulator core actually implements.**

Two places in `romwbw_emu` list that as required work before adopting a new
RomWBW release, and it is still open in both:

- `romwbw_emu/src/romwbw_pin.h:22-26` — "Changing the pin is not a version
  bump: it means re-cutting `emu_*.rom` from the new RomWBW release,
  refreshing every image in `disks/`, re-checking the HBIOS functions this
  core implements against that release's `proto.asm` ..."
- `romwbw_emu/DOWNSTREAM.md:424-430` — the same list, under "Changing the pin".

Both name a file that is not there. RomWBW v3.6.0 contains no `proto.asm`
anywhere — not in `Source/HBIOS/`, not in the release tree at all; the only
"proto" paths in the whole tag are the CH376 driver's `protocol.c` and
`protocol.h`. The files that carry the same information are
`Source/HBIOS/hbios.asm` — the dispatcher itself, 263,153 bytes in 3.5.1 and
267,954 in 3.6.0 — and `Source/Doc/SystemGuide.md`. Whatever the task is
called, that is what has to be diffed, and it has not been.

Do not read the identical `BF_*` equates as a substitute. Identical equates
prove the function *numbers* did not move. They say nothing about whether the
behaviour behind a number changed, whether a function the emulator stubs out
is now on a path a 3.6.0 guest takes, or whether 3.6.0's CBIOS and ROM
applications call anything the emulator does not implement. That is what a
dispatcher diff would tell you, and it has not been done.

Consequently, what has been verified about the 3.6.0 set is what the build
verifies: the ROMs carry the right HCB bytes and no foreign CBIOS banner,
every `CBIOS v` banner found in a published image reads exactly
`CBIOS v3.6.0 [WBW]` — three bootable images, `hd1k_cpm3`, `hd1k_zpm3` and
`hd1k_z3plus`, carry no banner for the check to look at — the combo carries
`w8.com` and `r8.com` with the `HBF_HOST_CAPS` interlock, and every published
size and hash matches. The artifacts have been checked. The runtime has not —
and cannot be, from a released client, until the ROM pin becomes runtime
state.

That is why `versions/3.6.0/version.json` says `"status": "preview"` and
`"default": false`.

## The dev-snapshot trap

This one deserves its own section because it is the failure that produces a
plausible-looking wrong ROM with no error anywhere.

`romwbw_emu/archive/romwbw-v3.6.0/SBC_simh_std_v360.rom` is **not** the v3.6.0
release. It is a development snapshot:

    strings: "ROMWBW v3.6.0-dev.46, SBC_simh_std, 2025-12-12"
             "RomWBW HBIOS v3.6.0-dev.46, 2025-12-12"
             "CBIOS v3.6.0-dev.46 [WBW]"
    size:    524288
    sha256:  4b387ec4137ce49d65044a7298855a9327b6182cc0c3aa2b8e90cb526bf1921c

Its HCB at offset `0x103` reads:

    57 a8 36 00

That is byte-for-byte what the real v3.6.0 release ROM reads. RomWBW's packed
version bytes have no field for a pre-release suffix, so `3.6.0-dev.46` and
`3.6.0` are indistinguishable to any version-byte check. Every check in that
family blesses it: `emu_validate_rom_hcb`
(`romwbw_emu/src/emu_init.cc:52-60`), the ROM pass of
`romwbw_emu/roms/verify_romwbw_pin.sh` (`roms/verify_romwbw_pin.sh:150-197`,
version bytes and `CB_PLATFORM` only), and this repo's own stock-ROM check at
`tools/build_rom.sh:78-81`.

Splice its banks 1-15 into an emulator ROM and you get a 512 KB file that
passes the HCB check, loads, and boots — carrying a December-2025 development
build of the ROM-resident loader, applications and ROM disk while claiming to
be the March-2026 release. The only thing that betrays it is the banner
string.

### How this repo defends against it

1. **The input is fetched, not found.** `tools/fetch_romwbw.sh` downloads the
   `upstream.package_url` named in `versions/<ver>/version.json` and checks it
   against `upstream.package_sha256` before anything is extracted
   (`tools/fetch_romwbw.sh:36-57`). A snapshot's archive would not match the
   pinned hash. No script in this tree takes a ROM path from its caller: the
   only stock ROM a build reads is the one `fetch_romwbw.sh` unpacked. The
   cache directory it unpacks into (`$ROMWBW_CACHE`, default `$HOME/esrc`,
   `tools/common.sh:17`) can still be filled in by hand — which is exactly how
   the snapshot got into `romwbw_emu/archive/` in the first place — so see the
   limit below.

2. **The banner is matched in full, not by major.minor.**
   `tools/build_disks.sh:127-131` requires each image's `CBIOS v` banner, when
   it has one, to equal the literal string `CBIOS v<ver> [WBW]`, and
   `tools/verify_release.sh` re-derives it independently: `build_all.sh` runs
   it at the end of every build, and `publish_release.sh` refuses to upload
   anything that has not passed it. `CBIOS v3.6.0-dev.46 [WBW]` fails string
   equality. This is the only kind of check in the tree that can see a dev
   snapshot at all, and it covers the ROMs as well as the disks:
   `tools/verify_catalog.py:86-93` scans each published `.rom` whole — banks
   1-15 included — for any banner that is not the expected one, precisely
   because that is where a dev snapshot's ROM disk would show up.

3. **It is written down where a build would look.**
   `versions/3.6.0/version.json` carries the warning in its `notes`, and
   `tools/gen_catalog.py` copies those notes into
   `catalog/v0/3.6.0/catalog.json` and into `catalog/v0/index.json`, so it
   reaches anyone reading the published catalog.

Be clear about where each defence bites. `tools/build_rom.sh` checks only the
HCB bytes and the stock ROM's size, so it would splice a dev snapshot's banks
1-15 and write the ROM without complaint; nothing catches that until
`verify_release.sh` runs `verify_catalog.py` and the ROM banner check fails.
The pinned download is what stops the snapshot getting in at all, and the
banner check is the backstop if it does. If you ever build from a locally
supplied stock ROM — anything you put in `$ROMWBW_CACHE` yourself — check its
`strings` for `-dev.` before you trust the build. A version-byte check will
not do it for you.

## Adding RomWBW 3.7.0

RomWBW upstream has a v3.7.0 development series. When it releases, this is the
whole procedure. It touches no client and does not bump the interface version.

1. **Create `versions/3.7.0/version.json`.** Copy `versions/3.6.0/version.json`
   and set `romwbw_version`, `released`, `hbios.{major,minor,update,patch}`
   and the derived `ver_byte` / `upd_byte` / `sysver_de`, and
   `upstream.{tag,package_url,unpacked_dir}`. Set `"status": "preview"` and
   `"default": false`. **Omit `upstream.package_sha256`** — the first
   successful fetch records it for you (`tools/fetch_romwbw.sh:42-50`).

2. **`tools/fetch_romwbw.sh 3.7.0`.** Downloads the `Package.zip`, records its
   hash into `version.json`, and extracts only the build inputs:
   `Binary/SBC_simh_std.rom`, `Binary/RCZ80_std.rom` and `Binary/hd1k_*.img`.

3. **Create `versions/3.7.0/roms.json`.** Copy the 3.6.0 file and change
   `romwbw_version`. Only edit the entries if upstream renamed one of the two
   stock ROMs or changed its size — `tools/build_rom.sh:82` requires 512 KB.

4. **Create `versions/3.7.0/disks.json`.** List `Binary/hd1k_*.img` from the
   extracted release and write one entry per image **except `hd1k_blank.img`**.
   `hd1k_combo` gets `"diskdef": "wbw_hd1k_0"`,
   `"inject_utils": ["wbw_hd1k_0"]`, `"defaultSlot": 0` and its slice count;
   every other image gets `"diskdef": "wbw_hd1k"` and `"inject_utils": []`.
   Carry `name`, `description` and `license` forward for ids that already
   exist in 3.6.0, and write them for anything new.

5. **Do not create `versions/3.7.0/generation.json`.** `tools/gen_catalog.py`
   writes it, and hand-editing it breaks the cache-invalidation contract that
   iOS keys its disk wipe on.

6. **`tools/build_all.sh 3.7.0`.** Runs `build_utils.sh` first — the
   host-transfer utilities are per-interface, not per-release — then
   `fetch_romwbw.sh`, `build_rom.sh` and `build_disks.sh` for the version,
   then `gen_catalog.py` and `verify_release.sh`. It should need nothing else.
   If `build_disks.sh` rejects an image on its CBIOS banner, stop — you have a
   snapshot or a mixed set.

7. **Do the delta by hand and write it into this document.** At minimum, diff
   between the 3.6.0 and 3.7.0 sources: `Source/ver.inc`; the `BF_*` equates
   and the `HBX_*` / `HB_IDENT` layout in `Source/HBIOS/hbios.inc`;
   `Source/Images/diskdefs`; and the image list in `Source/Images/`. If
   `HB_IDENT` or any `HBX_XFC` offset moved again, the proxy must write the
   value at both the old and the new address, as it already does for
   `0xFFFC`/`0xFFFE` (`src/emu_hbios.asm:366-373`).

8. **Do the HBIOS dispatcher diff** — the job `romwbw_pin.h` and
   `DOWNSTREAM.md` still call the `proto.asm` diff, which in practice means
   `Source/HBIOS/hbios.asm` and `Source/Doc/SystemGuide.md`. It is outstanding
   for 3.6.0 (see above) and it is the one piece of this that a build script
   cannot do for you. Doing it for 3.7.0 without having done it for 3.6.0
   leaves the same gap.

9. **Review the generated catalog before publishing.** `git diff` on
   `catalog/v0/3.7.0/catalog.json` and `catalog/v0/index.json` — both are
   tracked, and a diff of them is how you see what a release changed. Add a
   `notes` entry in `version.json` for anything a client must know — a moved
   ABI offset, an NVRAM-affecting change, an image that disappeared — and
   regenerate so it reaches the catalog.

10. **Publish with `tools/publish_release.sh 3.7.0`**, whose header documents
    the two-tag layout. Assets go on the immutable tag `v0-romwbw-3.7.0`; only
    `index-v0.json` goes on the floating `catalog-v0` tag. Never move an asset
    between tags — GitHub release asset URLs cannot be redirected, so every tag
    has to stay live for as long as any client points at it.

11. **Leave it `preview` until a client can run it.** Flip `status` and
    `default` in `version.json` and regenerate only after a client can
    actually load that ROM. 3.6.0 has been sitting at `preview` for exactly
    this reason.

Adding a RomWBW version is not an interface change. No `v0` to `v1` bump, no
client rebuild, no change to any existing tag —
[INTERFACE_V0.md](INTERFACE_V0.md) says what would require one.
