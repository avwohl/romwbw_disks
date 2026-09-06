# Client migration

What each client has to change to consume the interface-v0 catalog, and in what
order. The artifacts are published as of 2026-09-04, the emulator blocker was
cleared on 2026-09-05 (`romwbw_emu` v1.39), and **all three clients were
migrated the same day** — see "Suggested order" for what each commit carries.

**None of it has been compiled.** The migration was written on a Linux machine
with no Xcode, no Android SDK or NDK, and no MSVC or Windows. What could be
checked without those is recorded in each client's own changelog, tier by tier;
what remains is in each client's `MANUAL_CHECKS.md`. Nothing here has run on a
phone, a tablet or a PC, and no store build exists.

Read [INTERFACE_V0.md](INTERFACE_V0.md) first for what the contract promises,
and [CATALOG_SCHEMA.md](CATALOG_SCHEMA.md) for the documents themselves.

## The blocker: done

Everything below is distribution plumbing and can be done incrementally. One
thing could not, and it is now finished.

`emu_validate_rom_hcb` compared the loaded ROM's HCB bytes at `0x105`/`0x106`
against the compile-time `ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` from
`src/romwbw_pin.h` and returned a refusal that `emu_load_rom` turned into a
failed load. A build pinned to 3.5.1 could not load a 3.6.0 ROM at all.

**`romwbw_emu` v1.39 makes it runtime state read from the ROM being loaded.**
All five sites now derive the version from the loaded ROM rather than holding
a copy — and the two RAM-only ones were the dangerous ones, because
`roms/verify_romwbw_pin.sh` reads bytes out of a built ROM and cannot see
emulated RAM at all:

| Site | What it does now |
|---|---|
| `emu_init.cc` `emu_validate_rom_hcb` | refuses only a release the core has never been run against, naming the supported list; `--allow-untested-romwbw` overrides |
| `hbios_dispatch.cc` `HBF_SYSVER` | returns the loaded ROM's bytes — this is what the guest CBIOS compares against |
| `hbios_dispatch.cc` `recalcNvramChecksum` | seeds from the loaded ROM's version bytes |
| `emu_init.cc` `emu_setup_hbios_ident` | HBIOS ident block, written into RAM |
| `emu_init.cc` `emu_init_ram_bank` | CBIOS page-zero stamp at `0x42`/`0x43`, written into RAM |

Deriving rather than storing is what closes the RAM-only hazard: there is no
cached value to go stale and no initialisation order to get wrong, only a read
of ROM bank 0. Verified from inside the guest — a CP/M program that reads
`0x42`/`0x43`, the ident block and `HBF_SYSVER` reports `3510` under a 3.5.1
ROM and `3600` under a 3.6.0 ROM, on all of them.

Note also that `emu_hbios.asm` in this repo takes its version bytes from a
generated `romwbw_ver.inc` (`src/emu_hbios.asm:9`, written by
`tools/build_rom.sh:50` out of `versions/<ver>/version.json`), so bank 0 was
never a place the pin had to be edited.

### The API a client uses now

`ROMWBW_PIN_STR` and friends no longer exist. `emu_init.h` offers instead:

| Call | Use |
|---|---|
| `emu_romwbw_supported_list()` | `"3.5.1, 3.6.0"` — for an About screen shown before any ROM is loaded |
| `emu_romwbw_release_loaded(mem, &r)` | the release actually running, once a ROM is in memory |
| `emu_romwbw_release_of_image(buf, n, &r)` | inspect a downloaded image before offering it in a picker |
| `emu_romwbw_release_str(r, buf, n)` | `"3.6.0"` for display |
| `emu_romwbw_release_supported(r)` | can this build boot it? |

`emu_romwbw_release_of_image()` is the useful one for a download UI: it answers
from the first 264 bytes, so a client can check an image it has just fetched
without loading it into the emulator.

## Interim posture: filter, do not choose — still, for now

The emulator can load either release. **No released client contains that
emulator yet**, and each ships one bundled ROM. So until a client rebuilds:

1. fetch `index-v0.json`
2. keep only entries whose `hbios.ver_byte` and `hbios.upd_byte` match the
   version it was compiled for
3. use that entry's `catalog_url`

It can do that without downloading a catalog, let alone a 512 KB ROM. If the
list comes back empty, that is a real condition worth reporting — it means this
repo has stopped publishing the RomWBW version that build can run.

Once a client is rebuilt on v1.39 or later, the same code offers the whole list
instead — and should ask the core rather than assume, since a client can now be
newer or older than the core it compiles: keep an entry when
`emu_romwbw_release_supported({ver_byte, upd_byte})` says yes. Hardcoding
"offer everything" would break the moment this repo publishes a release the
client's core has not been checked against.

## Per-client work

> **This section describes each client as it stood BEFORE the migration**, and
> is kept because it is the reasoning the migration was written against. Much
> of what it names is now gone: `releaseTag` / `RELEASE_TAG`,
> `checkCatalogVersionAndInvalidate`, `parseDiskCatalogXML` and `parseDisksXml`
> were deleted rather than repointed. Line numbers here were already drifting
> before that and should be read as "look for this symbol", not as an address —
> several were measured wrong twice. For what the code does now, read the
> client's own changelog entry.

### All three GUI clients

**Replace the single pin.** DONE on 2026-09-05 in all three clients; this is
what was there and what to look for if you are reading an older tree. Each held
a constant with the same value:

| Client | File | Symbol |
|---|---|---|
| ioscpm | `iOSCPM/Views/EmulatorViewModel.swift` | `releaseTag = "v1.4.12"` |
| cpmdroid | `app/src/main/java/com/awohl/cpmdroid/data/DiskCatalogRepository.kt:45` | `RELEASE_TAG = "v1.4.12"` |
| z80cpmw | `z80cpmw/DiskCatalog.cpp:38` | `RELEASE_TAG = L"v1.4.12"` |

Each interpolates it into a `disks.xml` URL and a download base. Those become:
a constant index URL, plus a selected RomWBW version, plus `base_url` read from
the catalog. Watch the trailing-slash difference — iOS's base has none and the
parser appends `"/" + filename` (in its XML parser's `didEndElement`); Android's and
Windows's have one. Reading `base_url` from the catalog removes that
inconsistency, so remove it rather than reproducing it.

**Migrate storage keyed on bare filenames.** All three store downloaded images
in one flat directory named by catalog filename, and all three record saved
state the same way:

- iOS `Documents/Disks/`; the four disk slots are persisted as bare filenames
  under the `"selectedDisks"` `UserDefaults` key
  (written by `persistSelectedDisks()`)
- Android `externalFilesDir/Disks` plus a `ModifiedDisks` directory
  (`DiskDownloadManager.kt:50`, `:241`); disk slots persisted as bare filenames
  under `disk_slot_0..3` (`SettingsRepository.kt:37,61-69`)
- Windows `downloadDir + "\\" + filename` (`DiskCatalog.cpp:191`) with a ledger
  at `<dataDir>\disk_ledger.json` (`DiskCatalog.cpp:733`) keyed on
  `DiskLedger::fold(filename)` (`DiskLedger.cpp:17`)

v0 filenames deliberately differ from today's (`hd1k_combo-v0-3.5.1.img`, not
`hd1k_combo.img`) so two RomWBW generations can coexist. That means **every
saved profile, every disk-slot preference and every ledger key needs a
migration**, or users silently lose their configured disks. Write the migration
before changing the URLs, not after.

A reasonable migration: on first run under the new scheme, map each stored bare
filename to `<stem>-v0-<the version this build is pinned to>.<ext>`, rename the
file on disk if it is present, and leave anything unrecognised alone.

**Handle two catalog levels.** The index is a list; the catalog is what today's
`disks.xml` is, plus a `roms` array. A client that only wants disks can ignore
`roms` entirely. What the compatibility rules do require of a client that reads
it ([CATALOG_SCHEMA.md](CATALOG_SCHEMA.md) §6.1) is that it key on `id`, not
hardcode the array's length, and not assume `emu_avw` is present.

**Ignore unknown fields.** Required by [CATALOG_SCHEMA.md](CATALOG_SCHEMA.md)
§6.1, and implied by [INTERFACE_V0.md](INTERFACE_V0.md), where adding a field
is explicitly not an interface bump. Adding a field must never break a shipped
client.

### ioscpm

- `checkCatalogVersionAndInvalidate` (`EmulatorViewModel.swift`)
  compares the catalog's version against UserDefaults `"catalogVersion"` and,
  when it differs, deletes the downloaded images the catalog names — disks the
  user imported themselves are kept. That key must become per-(interface,
  RomWBW version), and it must read the catalog's `generation` field.
  Otherwise a user switching 3.5.1 → 3.6.0 → 3.5.1 has their library deleted
  twice. `generation` is already designed for this: it advances only when
  artifacts actually change, and it is scoped per RomWBW version.
- `catalogCacheTagKey = "catalogCacheTag"` (`EmulatorViewModel.swift:168`)
  exists because `parseDiskCatalogXML` rebuilds URLs from the *current*
  `releaseTag`. Once `base_url` comes from the catalog document itself, the
  cache and the URLs cannot disagree, and this key's job changes — it should
  record the (interface, RomWBW version) the cache was fetched under.
- The NVRAM store is one UserDefaults key, `"emulatorNvram"`
  (`EmulatorViewModel.swift:199`). RomWBW's `NVSW_CHECKSUM` XORs the version
  bytes into its seed, so a blob saved under 3.5.1 fails validation under a
  3.6.0 ROM and silently resets to defaults. Namespace it per RomWBW version.
- `availableROMs` (`EmulatorViewModel.swift:110-112`) is a hardcoded
  one-element array naming `emu_avw.rom`. The catalog now serves ROMs with
  `default: true` on `emu_avw`, so this can become data. The bridge methods
  `loadROMFromPath:` and `loadROMFromData:` (`RomWBWEmulator.h:64-65`) already
  exist and are already on the live path, not dead code: Swift calls
  `loadROM(fromBundle:)` at `EmulatorViewModel.swift:792`, that delegates to
  `loadROMFromPath:` (`RomWBWEmulator.mm:147`), and that to `loadROMFromData:`
  (`:158`). So no new bridge work is needed — what is missing is a caller that
  hands them a downloaded path instead of a bundle one.
- **Before removing the bundled ROM**, note that `docs/ROM_ATTESTATION.md` is
  an App Store filing naming `emu_avw.rom` specifically (`:7`, `:44`) and
  citing `github.com/avwohl/romwbw_emu` as the GPLv3 corresponding-source URL
  (`:38`, `:49`). Moving the ROM to a download changes both that document and
  the review posture (the app would have no bootable ROM on first launch).
  Keeping a bundled default and offering the rest by download is the smaller
  change.

### cpmdroid

- `parseDisksXml` (`DiskCatalogRepository.kt:91-140`) makes zero
  `getAttribute` calls, so Android is blind to the catalog version attribute
  and carries none of the iOS wipe hazard. If it starts reading `generation`,
  it must not adopt the deletion behaviour with it.
- **Delete the W8 hot-patch** in `app/src/main/cpp/emu_io_android.cpp` (the
  `W8_BROKEN` scan; mind the `LOGI` immediately above it, which stays).
  It scans every loaded disk image for the bytes
  `fe 41 d8 fe 5b d0 c6 00` and pokes byte 7 to `0x20`, repairing a `w8.com`
  that um80 0.3.42 miscompiled (`add a,'a'-'A'` assembled as `add a,0`). The
  `w8.com` this repo builds carries the fixed sequence `fe41d8fe5bd0c620` —
  verified in `build/utils/w8.com` — so the patch does nothing here. It is also
  a liability: it scans every image it is handed and will rewrite any 8-byte
  match, in images it was never written for, 3.6.0 ones included. None of the
  44 published images under `build/v0-romwbw-3.5.1/` and
  `build/v0-romwbw-3.6.0/` contains `fe41d8fe5bd0c600`, so today it fires on
  nothing — but nothing constrains it either.

### z80cpmw

- `DiskCatalog.cpp:29-30` states it reads no attributes; that stays fine.
- `roms/` holds three checked-in 512 KB ROMs and nothing ever fetches one.
  `emu_avw.rom` and `emu_romwbw.rom` are byte-identical to each other (both
  sha256 `4b11402a…`). If ROMs come from the catalog, this directory, the
  vcxproj's two `PostBuildEvent` xcopies of `roms\emu_*.rom` (`:132`, `:179`),
  the three `<None Include>` entries (`:322`, `:325`, `:328`),
  `packaging/nsis/z80cpmw.nsi:115-120` and `build-msix.ps1` all shrink.
- `packaging/scripts/verify-disk-assets.sh` can go — it is the only um80
  consumer among the three GUI clients, and its own header (`:9-12`) says the
  disks are not tracked and no build target puts r8/w8 on them. **But its
  `06 e9 cf` probe must not simply disappear.** That check catches a class of
  bug no hash can: a `w8.com` that is syntactically valid and semantically
  obsolete, missing the `HBF_HOST_CAPS` interlock and therefore willing to hand
  an old emulator an unchecked host path. It now lives here, in
  `tools/build_utils.sh` (asserted at build time) and `tools/verify_catalog.py`
  (asserted against every published image that carries `w8.com`).
- **This client does not persist bare filenames at all.** `config::DiskConfig::path`
  is a full absolute path, so its migration has to rewrite paths and rename
  files together — the "map each stored bare filename" recipe above is the iOS
  and Android shape, not this one. The ledger is the part keyed on a folded
  filename.
- `DiskCatalog.h` documents the fetch contract as fire-and-forget with
  no cancel and no wait. That does not model "this ROM must land before the
  emulator can start", so downloading ROMs needs more than a URL change here.

### romwbw_emu

- ~~Make the pin runtime state (above). This is the whole feature.~~ **Done**,
  v1.39. Along the way two things were found that had nothing to do with the
  version and everything to do with why a wrong one could survive:
  - `src/makefile` had **no header dependencies at all** (`%.o: %.cc` and
    nothing else), so editing `romwbw_pin.h` — the file whose entire job was to
    be the single source of truth about the RomWBW version — rebuilt nothing
    and left the old value compiled in, silently. `-MMD -MP` now records them.
  - `roms/verify_romwbw_pin.sh` was **never run by anything** — not `make
    test`, not any CI job. `make -C src test` runs it now.
- `src/w8.asm`, `src/r8.asm`, `src/emu_hbios.asm` and `src/emu_rom.asm` now
  live in this repo. Removing them there breaks
  `disks/rebuild_disk_utils.sh:62-66`, `disks/verify_disk_utils.sh`,
  `roms/build_from_source.sh` and `make -C src test` (whose `test` target runs
  `verify_disk_utils.sh` at `src/makefile:191`); those either point here or go
  away.
- `disks/disks.xml` is a dead third catalog — `version="6"`, 21 entries, zero
  `<sha256>` elements, read by nothing in that tree, diverged from the
  published one in version, count and schema. **Deleted 2026-09-05.**
- `archive/romwbw-v3.6.0/SBC_simh_std_v360.rom` was a `v3.6.0-dev.46` snapshot
  from 2025-12-12, not the release. Its HCB reads `36 00`, identical to the
  real thing, so nothing in its content distinguishes it from a genuine build
  input — and `verify_romwbw_pin.sh` will not catch it either way, because it
  prunes `archive/` outright (`-name archive` in the find expression it builds
  at `:185`, deliberate — though for `archive/cpm22/`'s sake, not this file's,
  as that comment now says). **Deleted 2026-09-05**, recoverable as blob
  `141a027d`. This repo never used it — `tools/fetch_romwbw.sh` pulls the real
  `Package.zip` and pins it by sha256.
- `.github/workflows/release.yml:125` and `test.yml:95`, `:194` and `:258` all
  do a bare `git clone https://github.com/avwohl/cpmemu.git` — the default
  branch, unpinned, and the workflow comments say so in as many words.
  `cpmemu/README.md:835` claims CI pins `CPMEMU_REF 9a94e8d`. One of those is
  wrong; it is the README.

## Toolchain: the um80 question, answered

**No client needs um80, and no client build assembles any Z80 machine code.**

Verified: zero `.asm`, `.com`, `.rel` or `.img` files in the ioscpm, cpmdroid
and z80cpmw trees, and zero `PBXShellScriptBuildPhase` entries in the Xcode
project — the iOS build runs no scripts at all, so it cannot be assembling
anything. Android is stock AGP (`com.android.application` plus
`org.jetbrains.kotlin.android`) over a CMake build of C++ only. The Windows
project's build events are a `touch` (`copy /b` on `MainWindow.cpp`) and, in
both configurations, a `mkdir` plus an `xcopy` of `roms\emu_*.rom`; the Release
configuration additionally xcopies the VC++ runtime DLLs. No assembler in any
of them.

The single exception was `z80cpmw/packaging/scripts/verify-disk-assets.sh`, an
optional release gate that re-assembles `../romwbw_emu/src/{r8,w8}.asm` and
byte-compares (`:174-175`, `:303`). That is now this repo's job.

`um80` is not vendored anywhere in the five repos. It is a pip package from
[um80_and_friends](https://github.com/avwohl/um80_and_friends), and it is
deliberately unpinned: a um80 output change is *meant* to turn the build red,
and the fix is to rebuild and re-publish, not to pin an old assembler.

So after the migration, romwbw_disks holds the entire Z80 toolchain dependency
for the family, and no client needs an assembler.

## Suggested order

1. ~~**romwbw_emu:** make the pin runtime state.~~ **Done** (v1.39,
   2026-09-05). Nothing user-visible yet — no released client carries it.
2. ~~**This repo:** publish, then leave it alone while clients catch up.~~
   **Done** (2026-09-04). `tools/boot_test.sh` was updated to ask the emulator
   which releases it can run rather than assume one; it passes against both the
   old and the new core.
3. ~~**Each client, release A:** the storage/profile migration for versioned
   filenames.~~ **Written** 2026-09-05: `ioscpm` build 63
   (`CatalogMigration.swift`), `cpmdroid` 1.26 (`V0Migration.kt`), `z80cpmw`
   (`DiskMigrationV0.cpp`). All three rename rather than copy — 19 of the 20
   published 3.5.1 images are byte-identical to their pre-v0 selves, and a
   rename is what preserves the size and modification time the disk ledgers
   validate against.
4. ~~**Each client, release B:** switch to the index URL.~~ **Written** the
   same day. Every `RELEASE_TAG` / `releaseTag` is deleted rather than
   repointed; `base_url` comes from the catalog document, so the
   trailing-slash inconsistency between the three clients is gone rather than
   reproduced.
5. ~~**Each client, release C:** offer the RomWBW version list.~~ **Written**
   the same day, filtered by `emu_romwbw_release_supported()` in all three
   rather than by a hardcoded list, so a client that is older or newer than its
   core still offers only what that core can boot.
6. **Cleanup:** ~~the cpmdroid hot-patch~~, ~~`verify-disk-assets.sh`~~,
   ~~`romwbw_emu/disks/disks.xml`~~ and ~~the dev snapshot~~ — all deleted
   2026-09-05. **Not the duplicated Z80 sources**: listing them here was wrong.
   `romwbw_emu` still builds and verifies its own ROM and its own two tracked
   disk images from `r8.asm`, `w8.asm`, `emu_hbios.asm` and `emu_rom.asm`, so
   they have live consumers in `disks/rebuild_disk_utils.sh`,
   `disks/verify_disk_utils.sh`, `roms/build_from_source.sh` and `make -C src
   test`. Removing them would be a decision to make that repo a consumer of what
   this one publishes, and it needs a replacement for all of that first.

Steps 3, 4 and 5 were written as separate numbered releases inside each client
even though they were written together, because the ordering is the safety
argument: the rename runs before anything can fetch a catalog, so a device that
arrives at the later build without ever running the earlier one still renames
its files before a v0 name can land beside a pre-v0 one.

**What is left is not writing but running.** No store build of any client
exists, none of this has been compiled, and until a released client carries it
3.6.0 was promoted to `"status": "stable"` on 2026-09-05 anyway, because a
shipped client filters it out by `hbios.ver_byte` rather than by reading
`status` — the bytes are the safety mechanism, not the label.

## What must never happen

The old `avwohl/ioscpm` tags — at least `v1.4.5` and `v1.4.12` — must stay live
indefinitely. Builds carrying a compile-time `releaseTag` are hardwired to
those exact asset URLs, and GitHub release asset URLs cannot be redirected.
Older builds do not name a tag at all: they float on
`releases/latest/download/`, which makes whichever ioscpm release is marked
Latest load-bearing too — see [RELEASING.md](RELEASING.md) §6. Migrating
clients does not free those tags; only the last user uninstalling does.

`tools/check-shipped-disks.sh` — which was byte-identical in the four repos carrying
it when this was written (md5 `47b7437050018c7cb4f7687d09909dc6`, under its
then-name `tools/check-disk-pins.sh`; romwbw_disks has never had it) and is no longer, ioscpm's and cpmdroid's having been updated
by the migration itself while z80cpmw's and romwbw_emu's were not — stops
answering its question the moment a client migrates: it hardcodes `CATALOG_REPO="avwohl/ioscpm"`, treats
`hd1k_combo.img` as the single canary, and scans built artifacts for the regex
`v1\.[0-9]+\.[0-9]+`, which matches neither `v0` nor `3.5.1`. It then fails in
two directions at once. The artifact scan goes quiet: a scan that matches
nothing lands in the `"  "` case at `:232-233`, which is treated as no evidence
either way, so a migrated build is never checked and never complained about.
The tree check goes loud but useless: once the quoted `vX.Y.Z` is gone from the
client's source, `pin_of` (`:90-96`) returns nothing and the script prints
`NO PIN FOUND` and exits 1 for a client that is working correctly. Decide
whether it is rewritten or retired before the first client migrates — not
after.
