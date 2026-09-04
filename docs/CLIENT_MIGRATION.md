# Client migration

What each client has to change to consume the interface-v0 catalog, and in what
order. Nothing here has been done yet — no client change is in scope until the
artifacts in this repo are published and settled.

Read [INTERFACE_V0.md](INTERFACE_V0.md) first for what the contract promises,
and [CATALOG_SCHEMA.md](CATALOG_SCHEMA.md) for the documents themselves.

## The blocker comes first

Everything below is distribution plumbing and can be done incrementally. One
thing cannot.

`emu_validate_rom_hcb` (`romwbw_emu/src/emu_init.cc:52-60`) compares the loaded
ROM's HCB bytes at `0x105`/`0x106` against the compile-time
`ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` from `src/romwbw_pin.h`, and
returns a refusal that `emu_load_rom` turns into a failed load. A build pinned
to 3.5.1 cannot load a 3.6.0 ROM at all.

Until that becomes runtime state read from the ROM being loaded, "let the user
pick a RomWBW version" is not achievable: a client can only filter the index
down to the single version its own binary can boot.

Making it runtime state touches five places, and two of them are invisible to
every existing verifier because they exist only in RAM:

| Site | What it does |
|---|---|
| `emu_init.cc:52-60` | the refusal itself — must compare against the ROM, then keep what it found |
| `hbios_dispatch.cc:1537` | `HBF_SYSVER` returns `ROMWBW_PIN_DE`; this is what the guest CBIOS compares against |
| `hbios_dispatch.cc:697-707` | the NVRAM checksum seed XORs the version bytes |
| `emu_init.cc:283`, `:289` | the HBIOS ident block, written into RAM |
| `emu_init.cc:324-325` | the CBIOS page-zero stamp at `0x42`/`0x43`, written into RAM |

The two RAM-only copies are the dangerous ones: `roms/verify_romwbw_pin.sh`
checks assembled bytes in a built ROM, so it cannot see them. If they are
missed, the ROM loads and the guest still reports the wrong version.

Note also that `emu_hbios.asm` in this repo now takes its version bytes from a
generated `romwbw_ver.inc`, so bank 0 is no longer a place the pin has to be
edited. That part is already done.

## Interim posture: filter, do not choose

Before the runtime pin lands, a client should:

1. fetch `index-v0.json`
2. keep only entries whose `hbios.ver_byte` and `hbios.upd_byte` match the
   version it was compiled for
3. use that entry's `catalog_url`

It can do that without downloading a catalog, let alone a 512 KB ROM. If the
list comes back empty, that is a real condition worth reporting — it means this
repo has stopped publishing the RomWBW version that build can run.

After the runtime pin lands, the same code offers the whole list instead.

## Per-client work

### All three GUI clients

**Replace the single pin.** Today each holds one identical constant:

| Client | File | Symbol |
|---|---|---|
| ioscpm | `iOSCPM/Views/EmulatorViewModel.swift:161` | `releaseTag = "v1.4.12"` |
| cpmdroid | `app/src/main/java/com/awohl/cpmdroid/data/DiskCatalogRepository.kt:45` | `RELEASE_TAG = "v1.4.12"` |
| z80cpmw | `z80cpmw/DiskCatalog.cpp:38` | `RELEASE_TAG = L"v1.4.12"` |

Each interpolates it into a `disks.xml` URL and a download base. Those become:
a constant index URL, plus a selected RomWBW version, plus `base_url` read from
the catalog. Watch the trailing-slash difference — iOS's base has none and the
parser appends `"/" + filename`; Android's and Windows's have one. Reading
`base_url` from the catalog removes that inconsistency, so remove it rather
than reproducing it.

**Migrate storage keyed on bare filenames.** All three store downloaded images
in one flat directory named by catalog filename, and all three record saved
state the same way:

- iOS `Documents/Disks/`; `EmulatorProfile.swift:46-49` holds `romFilename:
  String` and `diskFilenames: [String]`
- Android `externalFilesDir/Disks` plus a `ModifiedDisks` directory; disk slots
  persisted as bare filenames under `disk_slot_0..3`
  (`SettingsRepository.kt:37,61-69`)
- Windows `downloadDir + "\\" + filename` with a ledger at
  `<dataDir>\disk_ledger.json` keyed on `DiskLedger::fold(filename)`

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
`roms` entirely — it must, per the compatibility rules.

**Ignore unknown fields.** Required by [INTERFACE_V0.md](INTERFACE_V0.md).
Adding a field must never break a shipped client.

### ioscpm

- `checkCatalogVersionAndInvalidate` compares the catalog's version against
  UserDefaults `"catalogVersion"` and deletes downloaded images when it differs.
  That key must become per-(interface, RomWBW version), and it must read the
  catalog's `generation` field. Otherwise a user switching 3.5.1 → 3.6.0 →
  3.5.1 has their library deleted twice. `generation` is already designed for
  this: it advances only when artifacts actually change, and it is scoped per
  RomWBW version.
- `catalogCacheTagKey = "catalogCacheTag"` (`EmulatorViewModel.swift:168`)
  exists because `parseDiskCatalogXML` rebuilds URLs from the *current*
  `releaseTag`. Once `base_url` comes from the catalog document itself, the
  cache and the URLs cannot disagree, and this key's job changes — it should
  record the (interface, RomWBW version) the cache was fetched under.
- The NVRAM store is one UserDefaults key, `"emulatorNvram"`. RomWBW's
  `NVSW_CHECKSUM` XORs the version bytes into its seed, so a blob saved under
  3.5.1 fails validation under a 3.6.0 ROM and silently resets to defaults.
  Namespace it per RomWBW version.
- `availableROMs` is a hardcoded one-element array naming `emu_avw.rom`. The
  catalog now serves ROMs with `default: true` on `emu_avw`, so this can become
  data. The bridge methods `loadROMFromPath:` and `loadROMFromData:`
  (`RomWBWEmulator.h:64-65`) already exist and are currently dead code.
- **Before removing the bundled ROM**, note that `docs/ROM_ATTESTATION.md` is
  an App Store filing naming `emu_avw.rom` specifically and citing
  `github.com/avwohl/romwbw_emu` as the GPLv3 corresponding-source URL. Moving
  the ROM to a download changes both that document and the review posture
  (the app would have no bootable ROM on first launch). Keeping a bundled
  default and offering the rest by download is the smaller change.

### cpmdroid

- `parseDisksXml` (`DiskCatalogRepository.kt:91-140`) makes zero
  `getAttribute` calls, so Android is blind to the catalog version attribute
  and carries none of the iOS wipe hazard. If it starts reading `generation`,
  it must not adopt the deletion behaviour with it.
- **Delete the W8 hot-patch** at `app/src/main/cpp/emu_io_android.cpp:1129-1147`.
  It scans every loaded disk image for the bytes
  `fe 41 d8 fe 5b d0 c6 00` and pokes byte 7 to `0x20`, repairing a `w8.com`
  that um80 0.3.42 miscompiled (`add a,'a'-'A'` assembled as `add a,0`). The
  `w8.com` this repo builds carries the fixed sequence `fe41d8fe5bd0c620` —
  verified — so the patch is dead code. It is also a liability: it rewrites
  bytes inside images it has never seen, including every 3.6.0 image.

### z80cpmw

- `DiskCatalog.cpp:29-30` states it reads no attributes; that stays fine.
- `roms/` holds three checked-in 512 KB ROMs and nothing ever fetches one.
  `emu_avw.rom` and `emu_romwbw.rom` are byte-identical to each other. If ROMs
  come from the catalog, this directory, the vcxproj `PostBuildEvent` xcopy,
  the three `<None Include>` entries, `packaging/nsis/z80cpmw.nsi:115-120` and
  `build-msix.ps1` all shrink.
- `packaging/scripts/verify-disk-assets.sh` can go — it is the family's only
  um80 consumer outside romwbw_emu, and its own header says the disks are not
  tracked and no build target puts r8/w8 on them. **But its `06 e9 cf` probe
  must not simply disappear.** That check catches a class of bug no hash can:
  a `w8.com` that is syntactically valid and semantically obsolete, missing the
  `HBF_HOST_CAPS` interlock and therefore willing to hand an old emulator an
  unchecked host path. It now lives here, in `tools/build_utils.sh` (asserted
  at build time) and `tools/verify_catalog.py` (asserted against every
  published image).
- `DiskCatalog.h:246-262` documents the fetch contract as fire-and-forget with
  no cancel and no wait. That does not model "this ROM must land before the
  emulator can start", so downloading ROMs needs more than a URL change here.

### romwbw_emu

- Make the pin runtime state (above). This is the whole feature.
- `src/w8.asm`, `src/r8.asm`, `src/emu_hbios.asm` and `src/emu_rom.asm` now
  live in this repo. Removing them there breaks
  `disks/rebuild_disk_utils.sh:63`, `disks/verify_disk_utils.sh`,
  `roms/build_from_source.sh` and `make -C src test`; those either point here
  or go away.
- `disks/disks.xml` is a dead third catalog — `version="6"`, 21 entries, zero
  `<sha256>` elements, read by nothing, diverged from the published one in
  version, count and schema. Delete it.
- `archive/romwbw-v3.6.0/SBC_simh_std_v360.rom` is a `v3.6.0-dev.46` snapshot
  from 2025-12-12, not the release. Its HCB reads `36 00`, identical to the
  real thing, so `verify_romwbw_pin.sh` would bless it. Delete it or rename it
  so it cannot be mistaken for a build input. This repo never uses it —
  `tools/fetch_romwbw.sh` pulls the real `Package.zip` and pins it by sha256.
- `.github/workflows/release.yml:125` and `test.yml:95` do a bare
  `git clone https://github.com/avwohl/cpmemu.git` — the default branch,
  unpinned. `cpmemu/README.md:835` claims CI pins `CPMEMU_REF 9a94e8d`. One of
  those is wrong; it is the README.

## Toolchain: the um80 question, answered

**No client needs um80, and no client build assembles any Z80 machine code.**

Verified: zero `.asm`, `.com`, `.rel` or `.img` files in the ioscpm, cpmdroid
and z80cpmw trees, and zero `PBXShellScriptBuildPhase` entries in the Xcode
project — the iOS build runs no scripts at all, so it cannot be assembling
anything. Android is stock AGP plus a CMake build of C++ only. The Windows
project's only build events are a `touch` and an `xcopy` of `roms\emu_*.rom`.

The single exception was `z80cpmw/packaging/scripts/verify-disk-assets.sh`, an
optional release gate that re-assembles `../romwbw_emu/src/{r8,w8}.asm` and
byte-compares. That is now this repo's job.

`um80` is not vendored anywhere. It is a pip package from
[um80_and_friends](https://github.com/avwohl/um80_and_friends), and it is
deliberately unpinned: a um80 output change is *meant* to turn the build red,
and the fix is to rebuild and re-publish, not to pin an old assembler.

So after the migration, romwbw_disks holds the entire Z80 toolchain dependency
for the family, and no client needs an assembler.

## Suggested order

1. **romwbw_emu:** make the pin runtime state. Nothing user-visible until this
   lands.
2. **This repo:** publish, then leave it alone while clients catch up.
3. **Each client, release A:** write the storage/profile migration for
   versioned filenames. Ship it. Do not change any URL yet.
4. **Each client, release B:** switch to the index URL, filter by the compiled
   pin, read `base_url` from the catalog. The legacy `disks-v0-<ver>.xml` on
   each tag exists so this step can happen before any parser is rewritten.
5. **Each client, release C:** offer the RomWBW version list for real, now that
   the emulator can load either ROM.
6. **Cleanup:** delete the cpmdroid hot-patch, `verify-disk-assets.sh`,
   `romwbw_emu/disks/disks.xml`, the duplicated Z80 sources, and the dev
   snapshot.

Steps 3 and 4 are separate on purpose. Combining them means a build that both
renames every stored file and changes where files come from, and if it goes
wrong there is no way to tell which half did it.

## What must never happen

The old `avwohl/ioscpm` tags — at least `v1.4.5` and `v1.4.12` — must stay live
indefinitely. Installed clients are hardwired to those exact asset URLs and
GitHub release asset URLs cannot be redirected. Migrating clients does not free
those tags; only the last user uninstalling does.

`tools/check-disk-pins.sh`, byte-identical in all five repos, goes blind the
moment a client migrates: it hardcodes `CATALOG_REPO="avwohl/ioscpm"`, treats
`hd1k_combo.img` as the single canary, and scans built artifacts for the regex
`v1\.[0-9]+\.[0-9]+`, which matches neither `v0` nor `3.5.1`. It will keep
exiting 0 while checking nothing. Decide whether it is rewritten or retired
before the first client migrates — not after.
