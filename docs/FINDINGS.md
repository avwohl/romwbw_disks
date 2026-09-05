# Findings

What the survey of the existing system turned up, kept because the next person
to touch a client will need it.

This document records **measurements**. It does not propose anything. The plan
lives in [CLIENT_MIGRATION.md](CLIENT_MIGRATION.md); the contract lives in
[INTERFACE_V0.md](INTERFACE_V0.md).

## Preamble

Everything below was measured on **2026-09-04**, against the working trees at
`~/src/ioscpm`, `~/src/cpmdroid`, `~/src/z80cpmw`, `~/src/romwbw_emu` and
`~/src/cpmemu`, and against live GitHub state via `gh api`.

Anything with a date on it is a measurement, not a constant. Release flags,
"Latest" pointers, App Store build numbers, asset counts and byte totals all
move. Re-derive them before relying on them. Line numbers are from the trees as
they stood on that date; `grep -n` before quoting one back.

## 1. The one version string and the three jobs it did

Each client compiles in a single GitHub release tag. All three hold the same
value, `v1.4.12`:

| Client | Citation | Declaration |
|---|---|---|
| iOSCPM | `ioscpm/iOSCPM/Views/EmulatorViewModel.swift:161` | `private static let releaseTag = "v1.4.12"` |
| CPMDroid | `cpmdroid/app/src/main/java/com/awohl/cpmdroid/data/DiskCatalogRepository.kt:45` | `private const val RELEASE_TAG = "v1.4.12"` |
| Z80CPMW | `z80cpmw/z80cpmw/DiskCatalog.cpp:38` | `static const std::wstring RELEASE_TAG = L"v1.4.12";` |

Z80CPMW's is a `std::wstring`, so it appears in built artifacts as UTF-16LE,
not UTF-8. Any scanner that looks for the pin in a binary has to search both
encodings.

Each interpolates the tag into a catalog URL and a download base:

    https://github.com/avwohl/ioscpm/releases/download/v1.4.12/disks.xml

iOS's `releaseBaseURL` has **no** trailing slash and the parser appends
`"/" + filename` (declared at `EmulatorViewModel.swift:163`, appended at
`:2515`). Android's `DOWNLOAD_BASE_URL` and Windows's `RELEASE_BASE_URL` **do**
end in a slash. Three spellings of the same string.

That one string selected three different things at once:

1. **Which disk images to download.** The tag names the release whose assets
   are the catalog.
2. **Which generation of the host-transfer ABI is inside those images.** `W8.COM`
   and `R8.COM` live on `hd1k_combo` slice 0; a change to their protocol is a
   change to the images, so it arrived as a new tag.
3. **Which RomWBW release the client's bundled ROM matched.** Implicitly. Nothing
   in the catalog says `3.5.1`; the tag was simply understood to mean the images
   whose CBIOS agrees with the pinned ROM.

Because those three are one string, publishing a disk image required rebuilding
and re-releasing every client. That is the problem this repository exists to
remove.

## 2. Why the catalog lived in ioscpm

The obvious question is why the three clients fetch their disk images from the
iOS app's release area, when `ioscpm` is *downstream* of `romwbw_emu` — it
consumes the emulator core, not the other way around. (`romwbw_emu` itself
fetches nothing: it tracks `disks/hd1k_combo.img` and `disks/hd1k_infocom.img`
in-tree.)

The answer is chronology, not design. First release per repository, from the
GitHub API:

| Repository | First release | Date |
|---|---|---|
| avwohl/ioscpm | `v1.0` | 2025-12-15 |
| avwohl/romwbw_emu | `v0.1.0` | 2025-12-17 |
| avwohl/cpmdroid | `v1.0` | 2026-01-13 |
| avwohl/z80cpmw | `v1.0.10` | 2026-01-16 |

`ioscpm` `v1.0` already carried the assets: `disks.xml` (1121 bytes),
`hd1k_combo.img`, `hd1k_cpm22.img`, `hd1k_games.img`, `hd1k_zpm3.img`,
`hd1k_zsdos.img`. When `cpmdroid` needed disks a month later, the images
already existed at a URL, and duplicating roughly 200 MB of identical binaries
into a second release area was obviously wasteful. So it pointed at ioscpm's
URL. `z80cpmw` did the same three days later. `romwbw_emu`, published two days
*after* ioscpm, never became the catalog home because by then there already was
one.

Repeated three times, that hardened into a rule. It was never a decision.

## 3. Where the version bytes live

Upstream RomWBW packs its version into two bytes: high nibble major/update, low
nibble minor/patch. `3.5.1` is `0x35 0x10`; `3.6.0` is `0x36 0x00`.

Every place in the pre-migration system that encodes a RomWBW version:

| # | Where | Citation | Form | Checkable? |
|---|---|---|---|---|
| 1 | The declared source of truth | `romwbw_emu/src/romwbw_pin.h:34-38` | four `#define`s plus `ROMWBW_PIN_STR "3.5.1"` | n/a |
| 2 | HCB in the assembled ROM | `romwbw_emu/src/emu_hbios.asm:113-114` | `db 035h` / `db 010h`, hand-copied | yes, by a separate script |
| 3 | Proxy ident block | `romwbw_emu/src/emu_hbios.asm:316-317` | `db 035h` / `db 010h`, hand-copied | yes, by the same script |
| 4 | ROM load gate | `romwbw_emu/src/emu_init.cc:52-60` | compares ROM `[0x105]`/`[0x106]` against `ROMWBW_PIN_VER_BYTE`/`ROMWBW_PIN_UPD_BYTE` | it *is* the check |
| 5 | `HBF_SYSVER` return | `romwbw_emu/src/hbios_dispatch.cc:1537` | `cpu->regs.DE.set_pair16(ROMWBW_PIN_DE);` | derived from #1 |
| 6 | NVRAM checksum seed | `romwbw_emu/src/hbios_dispatch.cc:704-705` | `xsum ^= ROMWBW_PIN_VER_BYTE; xsum ^= ROMWBW_PIN_UPD_BYTE;` | derived from #1 |
| 7 | RAM HBIOS ident block, 0xFF00 | `romwbw_emu/src/emu_init.cc:283` | literal `0x35` | **no** |
| 8 | RAM HBIOS ident block, 0xFE00 | `romwbw_emu/src/emu_init.cc:289` | literal `0x35` | **no** |
| 9 | CBIOS page-zero stamp, 0x42/0x43 | `romwbw_emu/src/emu_init.cc:324-325` | literals `0x35` and `0x10` | **no** |
| 10 | ROM file, HCB | offsets `0x105`/`0x106`, behind marker `'W' 0xA8` at `0x103`/`0x104` | assembled from #2 | yes |
| 11 | ROM file, proxy image | offsets `0x502`/`0x503` (`org 0500h`), landing at `0xFE02`/`0xFE03` once copied to RAM | assembled from #3 | yes |
| 12 | Most boot slices | the literal string `CBIOS v3.5.1 [WBW]` | upstream's own CBIOS | only by reading the image |

Items 7, 8 and 9 are the dangerous ones. They exist only in RAM after
`emu_init` runs; no verifier that inspects sources or built artifacts can see
them, and nothing derives them from `romwbw_pin.h`. Re-pinning by editing the
header and the assembly leaves those three untouched and silent.

> **Superseded 2026-09-05 for items 4-9.** The table above is a record of the
> pre-migration system and is left as measured. `romwbw_emu` v1.39 replaced
> items 4, 5, 6, 7, 8 and 9 with a read of the loaded ROM's HCB, so all six now
> derive from item 10 rather than from item 1 — including the three that were
> "**no**" in the Checkable column, which are now checkable the only way they
> ever could be: from inside the guest. A CP/M program reading `0x42`/`0x43`,
> the HBIOS ident block, the block `0xFFFC` points at, and `HBF_SYSVER` reports
> `3510` under a 3.5.1 ROM and `3600` under a 3.6.0 one. Item 1 survives as `ROMWBW_DEFAULT_*`, meaning only "the release
> this tree's own artifacts are cut from", plus `ROMWBW_SUPPORTED_RELEASES`,
> the list of releases the core will load. Items 2, 3 and 11 are unchanged in
> `romwbw_emu`; in *this* repo they come from a generated `romwbw_ver.inc`.

Measured in the ROMs this repository builds, at `0x100`:

    3.5.1:  c3 00 02 57 a8 35 10 00 04 a0 0f 10
    3.6.0:  c3 00 02 57 a8 36 00 00 04 a0 0f 10

`57 a8` is the `'W' ~'W'` marker; the two bytes after it are the version. The
same four-byte pattern occurs six times in each ROM: at `0x103` (the HCB), at
`0x500` (the proxy image), and at `0xB633`, `0xE633`, `0x75433` and `0x78C33`,
which are inside the banks lifted verbatim from the upstream stock ROM and
therefore track the release automatically.

**What this repository changed.** `tools/build_rom.sh:44-50` generates
`romwbw_ver.inc` from `versions/<ver>/version.json`, and
`src/emu_hbios.asm:9` does `include romwbw_ver.inc`. Items 2 and 3 become
`db RMV_VER` / `db RMV_UPD` at `src/emu_hbios.asm:121-122` and `:324-325`. One
source now builds a ROM for any release, and the two copies cannot drift from
each other or from the published catalog. Items 4 through 9 are in
`romwbw_emu` and are untouched by this repository.

## 4. The mismatch message

    *** WARNING: HBIOS/CBIOS Version Mismatch ***

This is **not** printed by the emulator. It is printed by RomWBW's own CBIOS,
running as Z80 code out of the boot slice inside the disk image, comparing
itself against what the HBIOS reports.

Upstream `cbios.asm` does:

    LD   B,BF_SYSVER
    RST  08
    LD   A,D
    CP   ((RMJ<<4)|RMN)

`D` is the first version byte, `(major<<4)|minor`. The comparison is
**major.minor only**. The update/patch byte in `E` is never examined.

Consequences:

- 3.5.0 against 3.5.1 does **not** warn. The nibbles are `3` and `5` either way.
- 3.5.x against 3.6.x **always** warns, in both directions.

On the emulator side the value comes from `HBF_SYSVER`
(`romwbw_emu/src/hbios_dispatch.cc`), which since v1.39 returns the version
bytes read out of the loaded ROM; before that it returned the compile-time
`ROMWBW_PIN_DE`. So the message means "the disk image and the loaded ROM
disagree about major.minor", nothing more and nothing less — which is why it is
now the only thing enforcing the ROM/disk pairing.

Most boot slices also carry the literal banner `CBIOS v<ver> [WBW]`, which is
the only thing that distinguishes builds the version bytes cannot — see the dev
snapshot trap in [ROMWBW_VERSIONS.md](ROMWBW_VERSIONS.md). Not all of them do:
a ZPM3 or CP/M 3 slice loads `BIOS3.SPR` and carries no `CBIOS v` banner at
all, which is why `tools/diskinfo.py` decides bootability from the boot track
and reports the banner separately (`tools/diskinfo.py:11-18,104-106`). In the
3.5.1 catalog, `hd1k_zpm3`, `hd1k_cpm3` and `hd1k_z3plus` are bootable with no
banner.

## 5. um80 and machine code in the clients

This was the question that prompted the survey: do the clients still need
`um80`, and do they still build any Z80 machine code?

**No client needs `um80`. No client build assembles any Z80 code.** Both
answers are unambiguous.

Evidence, all measured on 2026-09-04:

- `find` for `*.asm`, `*.com`, `*.rel` and `*.img` across `ioscpm/`,
  `cpmdroid/` and `z80cpmw/`, excluding `.git`, returns **zero** files in each
  of the three trees.
- `ioscpm/iOSCPM.xcodeproj/project.pbxproj` contains **zero**
  `PBXShellScriptBuildPhase` entries. There is no build script phase that could
  run an assembler.
- None of the three has a `.github/workflows/` directory at all, so no CI job
  installs `um80` either.
- `grep -rl 'um80\|ul80'` across the three trees returns exactly six files.
  Four are documentation: `ioscpm/README.md`,
  `ioscpm/docs/DISK_W8FIX_RUNBOOK.md`, `cpmdroid/README.md` and
  `z80cpmw/README.md`. The other two are
  `cpmdroid/app/src/main/cpp/emu_io_android.cpp` (a comment, see section 6) and
  `z80cpmw/packaging/scripts/verify-disk-assets.sh`.

Outside `romwbw_emu` — and outside this repository, whose `tools/build_rom.sh`
and `tools/build_utils.sh` both drive `um80`/`ul80` — the family's only real
`um80` consumer is that last one. Its `:123` and `:174` require `um80` and
`ul80`, re-assemble `../romwbw_emu/src/{r8,w8}.asm`, and byte-compare the
result against the copies it extracts from each release-candidate image. Its own
header, at `verify-disk-assets.sh:9-12`, states the situation plainly: the disks
are build output, they are not tracked in that repository, and no build target
puts `r8.com` or `w8.com` on them. Consistent with that, no `z80cpmw` GitHub
release carries a single `.img` asset — checked across all six published
releases.

`um80` itself is a pip package (`github.com/avwohl/um80_and_friends`) and is
deliberately unpinned in CI.

### What each client can delete

| Client | Safe to remove |
|---|---|
| iOSCPM | the `um80` mentions in `README.md` and `docs/DISK_W8FIX_RUNBOOK.md`; nothing in the build |
| CPMDroid | the `um80` mention in `README.md`; the hot-patch at `app/src/main/cpp/emu_io_android.cpp:1129-1147` (section 6) |
| Z80CPMW | the `um80` mention in `README.md`; `packaging/scripts/verify-disk-assets.sh` — **but see below** |
| all three | `tools/check-disk-pins.sh` (section 10) |

### The one thing that must not simply disappear

`verify-disk-assets.sh` contains one check no hash can make. At
`z80cpmw/packaging/scripts/verify-disk-assets.sh:277` it looks for the byte
sequence `06 e9 cf` inside the `w8.com` it extracted from the image:

    ld  b,0E9h      ; HBF_HOST_CAPS
    rst 8

That is `W8`'s probe for `EMU_HOST_CAP_SAFE_PATHS` before it hands a host path
to the emulator. A `w8.com` without it is syntactically valid, assembles
cleanly, hashes fine, and is semantically obsolete: it will give an old
emulator an unchecked host path. Only a machine-code check catches that.

**It now lives here, in two places.** `tools/build_utils.sh:42-50` asserts the
bytes are present in the freshly linked `w8.com` and refuses to continue
otherwise, and `tools/verify_catalog.py:25,135-137` re-checks them in every
published image whose catalog entry claims `host_transfer` — today only
`hd1k_combo` — after confirming `w8.com` and `r8.com` are in its slice-0
directory. That second check scans the image itself rather than an extracted
`.COM`. So the check moved upstream of publication instead of sitting
downstream of it in one platform's packaging directory. Deleting the z80cpmw
script is safe **only** because of that; deleting it without the replacement
would lose the check entirely.

## 6. The cpmdroid w8 hot-patch

`cpmdroid/app/src/main/cpp/emu_io_android.cpp:1129-1147` scans **every** loaded
disk image, byte by byte, for this eight-byte sequence:

    fe 41 d8 fe 5b d0 c6 00

and pokes byte 7 to `0x20` wherever it finds it.

**What it repairs.** `um80` 0.3.42 assembled `add a,'a'-'A'` as `add a,0`, so
the `W8.COM` built with it exported uppercase filenames. Every hd1k image built
before 2026-07-21 carries the broken byte, including everything in the ioscpm
`v1.4.5` catalog and any copy a user had already downloaded. The broken and
fixed builds differ in that one byte, so patching at load time was a way to fix
the installed base without forcing a re-download.

**Why it is now dead code.** Measured on 2026-09-04: the `w8.com` this
repository builds contains

    fe 41 d8 fe 5b d0 c6 20

— the fixed sequence. It does not match the signature, so the patch is a no-op
for anything published from here.

**Why it is also a liability.** It is a blind memory scan over the whole image
with no bound on which image, which RomWBW version, or which file inside it. It
would happily rewrite a byte inside a v3.6.0 image it has never seen, in a file
that has nothing to do with `W8`, if those eight bytes happen to occur. The
comment at `:1135-1137` already warns that `GetByteArrayElements` usually
returns a direct pointer on ART, so the caller's array — and possibly the file
behind it — may be modified in place. Carrying a blind patcher forward into a
release it was never tested against is a worse risk than the bug it fixes.

## 7. Client storage and saved state

All three clients store downloaded disks in a **flat directory, keyed on the
catalog filename alone**:

| Client | Directory | Citation |
|---|---|---|
| iOSCPM | `Documents/Disks/` | `ioscpm/iOSCPM/Views/EmulatorViewModel.swift:1760` |
| CPMDroid | `externalFilesDir/Disks`, plus `externalFilesDir/ModifiedDisks` | `cpmdroid/app/src/main/java/com/awohl/cpmdroid/data/DiskDownloadManager.kt:50,241` |
| Z80CPMW | `downloadDir + "\\" + filename`, with a ledger at `<downloadDir>\disk_ledger.json` keyed on `DiskLedger::fold(filename)` | `z80cpmw/z80cpmw/DiskCatalog.cpp:340,733`, `z80cpmw/z80cpmw/DiskLedger.cpp:17` |

Saved-state identity is filename-only too:

- iOS `EmulatorProfile` stores `romFilename: String` and
  `diskFilenames: [String]` — `ioscpm/iOSCPM/Views/EmulatorProfile.swift:46-48`.
- CPMDroid stores `disk_slot_0` .. `disk_slot_3` as preference strings —
  `cpmdroid/app/src/main/java/com/awohl/cpmdroid/data/SettingsRepository.kt:37,61-69`.
- Z80CPMW stores `struct DiskConfig { std::string path; bool isManifest; }` —
  `z80cpmw/z80cpmw/Config.h:24-27`.

So `hd1k_combo.img` for RomWBW 3.5.1 and `hd1k_combo.img` for 3.6.0 would
collide in the download directory, in the ledger, and in every saved profile.
There is no version anywhere in the key.

The v0 naming scheme (`hd1k_combo-v0-3.5.1.img`) breaks this **deliberately**.
Every published filename carries both versions, so two RomWBW generations can
sit in one flat directory without collision — which is exactly what none of the
three can do today. The cost is that every saved profile, every disk slot
preference and every ledger entry stops resolving on the day a client
migrates. That is a migration, not an accident. It is
[CLIENT_MIGRATION.md](CLIENT_MIGRATION.md)'s problem.

Three more storage facts that matter:

- **iOS is the only client that reads the catalog's `version` attribute.**
  Verified: `cpmdroid`'s `parseDisksXml`
  (`DiskCatalogRepository.kt:91-140`) makes zero `getAttribute` calls, and
  `z80cpmw`'s `parseCatalogXML` (`DiskCatalog.cpp:640`) reads no attributes
  either — a comment at `DiskCatalog.cpp:29-30` says so explicitly. On iOS,
  `checkCatalogVersionAndInvalidate`
  (`EmulatorViewModel.swift:1619-1652`) compares against the UserDefaults key
  `catalogVersion`, and on a difference calls
  `deleteCatalogDisks(named: catalogFilenames)` and shows an alert titled
  "Disk Catalog Updated". The in-tree build is the **narrowed** version —
  catalog-named files only, imported disks kept. The App Store fleet is 1.4.9
  (builds 36/37), which predates both the narrowing and the pin, and still
  floats on `releases/latest/download/`.
- **iOS has a second cache key.** `catalogCacheTagKey = "catalogCacheTag"`
  (`EmulatorViewModel.swift:168`), because `parseDiskCatalogXML` always rebuilds
  URLs from the *current* `releaseTag`. A cache written under one pin would
  otherwise pair the wrong hashes with the right URLs. The cache file is
  `Documents/Disks/disks_catalog.xml`.
- **NVRAM is stored under one key.** `nvramKey = "emulatorNvram"`
  (`EmulatorViewModel.swift:199`). RomWBW's `NVSW_CHECKSUM` XORs the version
  bytes into the seed (`hbios_dispatch.cc`, `recalcNvramChecksum`), so a blob
  saved under 3.5.1 fails validation under a 3.6.0 ROM and silently resets to
  defaults. That single key has to become per-version — the seed follows
  whichever ROM is loaded, so on a rebuilt client one install can boot both.

Also measured: the iOS ROM list is hardcoded to one element —

    let availableROMs: [ROMOption] = [
        ROMOption(name: "EMU AVW", filename: "emu_avw.rom"),
    ]

at `EmulatorViewModel.swift:110-112`. The bridge methods `loadROMFromPath:` and
`loadROMFromData:` are declared at
`ioscpm/iOSCPM/Bridge/RomWBWEmulator.h:64-65` and have **no caller outside the
bridge**: the only calls in the tree are `loadROMFromBundle:` chaining into
them at `RomWBWEmulator.mm:147` and `:158`, and nothing in Swift ever supplies
a path or a buffer. They are effectively dead code today and the hook a runtime
ROM picker would use tomorrow.

`z80cpmw` checks in three 512 KB ROMs under `roms/` and never fetches any;
`emu_avw.rom` and `emu_romwbw.rom` there are byte-identical to each other.

## 8. Live GitHub state as of 2026-09-04

All from `gh api repos/avwohl/ioscpm/...` on that date.

### The prerelease finding

    v1.4.12   prerelease=false   29 assets   2026-09-01T17:47:34Z
    v1.4.5    prerelease=true    30 assets   2026-07-25T13:31:36Z
    v1.4.11   prerelease=false   30 assets   2026-01-07T03:45:21Z

`releases/latest` resolves to **`v1.4.12`**.

`v1.4.12` is not a prerelease and **is** GitHub's "Latest". Four in-tree
documents state or assume the opposite; see section 9. This matters because the
App Store fleet (1.4.9) fetches from `releases/latest/download/` rather than
from a pinned tag, so it now sees `v1.4.12`'s catalog.

### The catalog hashes

Fetched and hashed directly from the release assets:

| Tag | `disks.xml` sha256 | Size | `version` attribute | Entries |
|---|---|---|---|---|
| `v1.4.5` | `6ae94b8c805d1461cd90aa31cef5888daec9d4e9b3e40cd8512992011dd71bca` | 7042 | `13` | 20 |
| `v1.4.11` | `6ae94b8c805d1461cd90aa31cef5888daec9d4e9b3e40cd8512992011dd71bca` | 7042 | `13` | 20 |
| `v1.4.12` | `e03cbbf57bc2fc91cac6868bb7bb646ada69641bad927a35fa695b515c9717db` | 7042 | `13` | 20 |

`v1.4.5` and `v1.4.11` serve a byte-identical catalog. `v1.4.12` differs from
them on exactly one line — `hd1k_combo.img`'s `<sha256>`, `be19984e…` becoming
`89b8ae1a…`. The `version` attribute is `13` in all three, so the iOS disk-wipe
**cannot currently fire** on a client moving between these pins.

The catalog is flat and one level deep: `<disks version="13">` with 20 `<disk>`
entries carrying `filename`, `name`, `description`, `size`, `license`, `sha256`
and `defaultSlot` (only `hd1k_combo` has the last). iOS requires only
`filename` and `name`.

### Asset inventory and byte totals

| Tag | Assets | Bytes |
|---|---|---|
| `v1.4.12` | 29 | 210,800,381 |
| `v1.4.5` | 30 | 262,175,039 |
| `v1.4.11` | 30 | 262,180,605 |
| `v1.4.3` | 30 | 219,183,778 |
| `v1.4.0` | 22 | 219,157,870 |
| `v1.2` | 22 | 219,157,870 |
| `v1.1` | 7 | 93,323,932 |
| `v1.0` | 6 | 84,935,777 |
| **total** | **176** | **1,570,915,252 (1.46 GiB)** |

`v1.4.12` carries 20 `hd1k_*.img` plus `disks.xml` plus eight help files.
`v1.4.5` carries the same set plus `hd1k_combo_ioscpm_w8fixed.img`, which is
why it has one more asset and 51 MB more.

For comparison, what this repository publishes per RomWBW version, measured
from `build/`:

| Tag | Files | Bytes |
|---|---|---|
| `v0-romwbw-3.5.1` | 24 (2 ROMs, 20 disks, catalog, XML) | 211,831,468 (202.0 MiB) |
| `v0-romwbw-3.6.0` | 28 (2 ROMs, 24 disks, catalog, XML) | 245,390,244 (234.0 MiB) |

### Old asset URLs cannot be redirected

Builds already in service are hardwired to `.../v1.4.5/...` and
`.../v1.4.12/...`. GitHub release asset URLs have no redirect mechanism: you
cannot point an old asset name at a new one, and deleting a tag makes every URL
under it a 404 with no forwarding. **Those tags have to stay live
indefinitely**, for as long as any installed client points at them. The same
constraint applies to every tag this repository publishes, which is why the
mutable entry point is a small `index-v0.json` alone on the `catalog-v0` tag
and the large artifacts live on immutable per-version tags.

## 9. Stale documentation found along the way

In-tree documents that are now known wrong. Listed because someone will read
them and believe them.

**1. Four documents treat `--prerelease` as still in force.**

- `ioscpm/docs/DISK_W8FIX_RUNBOOK.md:135` — "`v1.4.12` (2026-09-01,
  prerelease)"; `:245` gives a gate command asserting `.prerelease` "must be
  true".
- `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md:376-378` — "Done, as a
  prerelease … `releases/latest` is still `v1.4.11`; `v1.4.12` reports
  `prerelease: true`".
- `ioscpm/KNOWN_PROBLEMS.md:109` — "`--prerelease` on an asset carrier is
  load-bearing rather than cosmetic".
- `ioscpm/docs/DISK_CATALOG_PINNING.md:146` — "keep any v3.6.0 ioscpm release
  marked **prerelease** so it can't become 'Latest'".

*Actually true:* `v1.4.12` is `prerelease=false` and **is** `releases/latest`.
Whatever happened after publication, the flag is not set now. The two CHANGELOG
entries that say the same thing (`ioscpm/CHANGELOG.md:343,570` and
`romwbw_emu/CHANGELOG.md:118`) are dated historical records rather than standing
instructions, but they are equally false as descriptions of today.

**2. `cpmemu/README.md:835` claims romwbw_emu's CI pins a `CPMEMU_REF`.**

It says the workflows "clone `avwohl/cpmemu` and check out a pinned
`CPMEMU_REF`, `9a94e8d` at the v4.7.0 tag."

*Actually true:* there is no pin. `romwbw_emu/.github/workflows/release.yml:125`
and `.github/workflows/test.yml:95` (and `test.yml:194` and `:258`) all do a
bare `git clone https://github.com/avwohl/cpmemu.git` with no ref and no
subsequent `git checkout`. All four track cpmemu's default branch. The
workflows' own comments say so — `test.yml:192-193` reads "like them it tracks
cpmemu's default branch rather than a ref" — and `release.yml:6` notes that
`CPMEMU_REF` "existed here" in the past tense. The README describes a pin that
was removed.

**3. `cpmdroid/README.md:78` says the disks are "pinned at tag v1.4.5".**

*Actually true:* `DiskCatalogRepository.kt:45` reads `v1.4.12`.

**4. `ioscpm/docs/DISK_DISTRIBUTION.md` says `v1.4.5` throughout.**

At `:88` ("`releaseTag` … currently `v1.4.5`"), `:90-91`, `:96`, `:122`, `:125`
and `:177`.

*Actually true:* `EmulatorViewModel.swift:161` reads `v1.4.12`. The one claim in
that file which is still correct is `:125`, that `v1.4.5` is marked
prerelease — it is.

**5. The "Reserved" comment on `emu_hbios.asm`'s `0xFFFE` `dw`.**

`romwbw_emu/src/emu_hbios.asm:359` reads:

    dw  HBX_LOC     ; 0xFFFE: Reserved

*Actually true:* it is not reserved. RomWBW v3.6.0 moved `HB_IDENT` from
`HBX_XFCFNS + 14` to `HBX_XFCFNS + 12`, i.e. from `0xFFFE` to `0xFFFC`. The
emulator happens to write `dw HBX_LOC` at **both** addresses, which is the only
reason it is accidentally compatible with both releases. This repository
corrected the comment — `src/emu_hbios.asm:367` now names what the word
actually is, and `:369-373` records that the duplicate must not be removed as
tidying.

## 10. Open questions this repository does not answer

Stated as questions because nobody has decided, not because the answers are
obvious.

**~~Does the RomWBW pin become runtime state, or does each client ship
per-version builds?~~ ANSWERED, 2026-09-05: runtime state.** `romwbw_emu`
v1.39 reads the release out of the loaded ROM's HCB every time it is asked, at
all five sites — `emu_validate_rom_hcb`, `HBF_SYSVER`, the NVRAM checksum seed,
the HBIOS ident block and the CBIOS page-zero stamp at `0x42`/`0x43`. The last
two are the ones that existed only in RAM where no verifier could see them, and
deriving rather than storing is what removed the hazard rather than relocating
it: there is no cached copy and no initialisation order, only a read of ROM
bank 0. One binary now boots both published releases; the load-time check
refuses only a release the core has never been *run* against, and names the
list it can run.

Measured from inside the guest, since that is the only place the two RAM-only
sites are visible: a CP/M program reading `0x42`/`0x43`, the HBIOS ident block,
the block `0xFFFC` points at, and `HBF_SYSVER` reports `3510` under a 3.5.1 ROM
and `3600` under a 3.6.0 ROM — all four, both releases.

What is left is client work, not a design question: no released client carries
that core yet, so a shipped client should still filter the index down to the
version it was built for. See [CLIENT_MIGRATION.md](CLIENT_MIGRATION.md).

**Should ROMs be downloaded, or stay bundled?** Two separate reasons to be
careful. App Store review posture: a bundled ROM is a reviewed asset, a
downloaded one is not, and the difference is visible to review. And
`ioscpm/docs/ROM_ATTESTATION.md` is a filing with Apple that names
`emu_avw.rom` specifically (`:7`, `:44`) and cites
`github.com/avwohl/romwbw_emu` as the GPLv3 corresponding-source URL (`:38`,
`:49`). Renaming or relocating that ROM has legal-document consequences, and
this repository's naming (`emu_avw-v0-3.5.1.rom`) does exactly that. Somebody
has to decide whether the filing gets amended or whether iOS keeps a bundled
`emu_avw.rom` under the old name.

**What replaces `tools/check-disk-pins.sh`?** It is byte-identical in all five
repositories (md5 `47b7437050018c7cb4f7687d09909dc6` — verified in `ioscpm`,
`cpmdroid`, `z80cpmw`, `romwbw_emu` and `cpmemu`). It hardcodes
`CATALOG_REPO="avwohl/ioscpm"`, treats `hd1k_combo.img` as the single canary,
greps each port for one quoted `vX.Y.Z`, and scans built artifacts for the
regex `v1\.[0-9]+\.[0-9]+` in both UTF-8 and UTF-16LE. That regex matches
neither `v0` nor `3.5.1`. **It goes blind the moment any client migrates** —
not loudly, not with an error, just silently passing. Nothing here replaces it,
and something should.

**Should `romwbw_emu/disks/hd1k_infocom.img` be published?** It is tracked in
that repository (8,388,608 bytes, sha256 `75a8a618…`) and these exact bytes
have never appeared in any release, in any repository. An asset *named*
`hd1k_infocom.img` did ship in ioscpm `v1.1`, `v1.2`, `v1.4.0` and `v1.4.3` —
same 8,388,608 bytes but a different image, sha256 `7f33738c…` — and was
dropped from `v1.4.5` onward. Meanwhile upstream RomWBW v3.6.0 ships its own
`hd1k_infocom.img`, which this repository does publish as
`hd1k_infocom-v0-3.6.0.img`. Whether the hand-built 3.5.1-era one should now be
published alongside it, retired, or compared against upstream's first, is
undecided.

**Has anyone diffed v3.6.0's `Source/HBIOS/proto.asm` against the HBIOS
functions the emulator core actually implements?** The question was
unanswerable as posed: **there is no `proto.asm` in any RomWBW release.**
`romwbw_emu/DOWNSTREAM.md` now says so outright — the files that carry that
information are `Source/HBIOS/hbios.asm` and `Source/Doc/SystemGuide.md` — and
`romwbw_emu/src/romwbw_pin.h` no longer names the file at all: its "Adding a
release" list is build, boot, round-trip `R8`/`W8`, add the `X()` line.

What was done instead, on 2026-09-05, is that 3.6.0 was **run**: CP/M 2.2,
banked CP/M 3, ZPM3, Z3PLUS, ZSDOS and NZCOM all boot from the published
images; `R8`/`W8` round-trip a file byte-identically, exercising the private
`0xE1`–`0xEA` block including the `HBF_HOST_CAPS` interlock; the boot loader
validates NVRAM, so the checksum seed agrees with the ROM's own SYSCONF; and a
mismatched ROM/disk pair still warns in both directions.

The semantic pass over `hbios.asm` (263,153 bytes in 3.5.1, 267,954 in 3.6.0)
is still not done, and identical `BF_*` equates are still not a substitute for
it. Booting six operating systems exercises much of that surface without
enumerating it. But "supports 3.6.0" is no longer a claim about artifacts
alone.

**Does `cpmemu/util/cpm_disk.py` have one home or two?** This repository now
vendors it at `tools/cpm_disk.py` as the canonical copy. `cpmemu`'s copy stays
for now because `cpmemu/src/makefile:207` installs it as `cpm_disk`, and the
separate `mpm2` repository (not checked out in this environment) calls it
through a `$CPM_DISK` variable defaulting to `~/src/cpmemu/util/cpm_disk.py`.
Removing it would break both. Whether the two copies get reconciled, or one
becomes a shim, is not decided here.
