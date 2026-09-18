# tools

The build and verify pipeline. Run `build_all.sh`; everything else is a stage
of it or a check on it.

| Script | Does |
|---|---|
| `common.sh` | shared settings, sourced not run. Owns `IFACE`, the asset-naming and release-tag functions, and the toolchain check. |
| `build_all.sh` | **the whole pipeline.** Builds every artifact for one or all RomWBW versions, generates the catalogs and verifies the result. Everything below is a stage of it or a check on it. |
| `check_upstream.sh` | asks GitHub which RomWBW releases exist, which are carried here, and which are prereleases |
| `fetch_romwbw.sh` | downloads an upstream `Package.zip`, pins it by sha256 in `versions/<ver>/version.json`, extracts only the build inputs. Refuses a prerelease tag. |
| `build_utils.sh` | assembles `w8.com` and `r8.com`, and asserts `w8.com` still carries the `06 e9 cf` capability interlock |
| `build_rom.sh` | generates `romwbw_ver.inc`, assembles bank 0, overlays banks 1–15 from a stock ROM, verifies the HCB |
| `build_disks.sh` | copies the stock images, injects `w8`/`r8` where the manifest says, verifies each CBIOS banner |
| `gen_catalog.py` | writes the catalogs and the index from the built artifacts — every size and hash computed, none transcribed. `--index` regenerates only the index (needs a populated `build/`); `--help-block` regenerates only the committed index's `help` block from `help/`, which needs no build at all. |
| `verify_catalog.py` | re-derives every claim a catalog makes, independently of the generator, and with `--index` every claim the index makes - including the `help` block's seven sizes and hashes, which nothing re-derived until 2026-09-18. Works on downloaded assets too: it looks for a topic under `<dir>/help-v0/` first and the checkout's `help/` second, and prints which answered. |
| `verify_release.sh` | runs `verify_catalog.py` across every version and the index |
| `check_committed.py` | checks the committed `catalog/` documents against `versions/<ver>/*.json` without building anything - no 420MB of downloads, no Z80 toolchain - so it can run on every push. Also re-derives the index's `help` block from `help/`; when that fires, the fix is `gen_catalog.py --help-block`. |
| `check_source_drift.sh` | do this repo's Z80 sources still agree with romwbw_emu's? All three - `r8.asm`, `w8.asm` and `emu_hbios.asm` - must be byte-identical; `emu_rom.asm` was a fourth until 69d2a71 deleted it from here. `emu_hbios.asm` was the documented exception until romwbw_emu v1.44 parameterised its copy through the same generated `romwbw_ver.inc`. It then assembles both trees' `emu_hbios.asm` and compares the 32 KB bank 0, and builds `r8.com`/`w8.com` from romwbw_emu's sources; it needs no ROM and no disk image. Skips when romwbw_emu is not beside this repo. |
| `boot_test.sh` | **the release gate.** Boots every published release, unconditionally, and since 2026-09-18 all six operating systems on its images rather than CP/M 2.2 alone: each must reach a CP/M prompt with the right `CBIOS v<ver> [WBW]` banner and no mismatch warning, report the release it read from the ROM, warn on a disk from another release, round-trip a file through `R8`/`W8`, boot ZSDOS, NZCOM, banked CP/M 3, ZPM3 and Z3PLUS, and show `NV Switches Found`. CP/M 3's banner names the HBIOS release, so that assertion covers the pairing too; NZCOM is checked by ZCPR3 answering `No File` to `PATH`, because its volume label differs between releases. No refusal branch - a ROM that does not boot is a failure (romwbw_emu v1.44 dropped the release allowlist this used to parse off `--version`). Publishing into `index-v0.json` asserts this passed, and since 2026-09-18 `publish_release.sh` enforces that: a real publish runs it and refuses all three of its exit-0 non-passes - no emulator, a version not built, and the mismatch guard not exercised for want of another release's image to try. It still skips on its own, for a build machine with no emulator. |
| `publish_release.sh` | uploads a built tree: the immutable `v0-romwbw-<ver>` tags, then the mutable `catalog-v0` index last. Gates on `verify_release.sh` and `boot_test.sh` first, compares each already-published asset by sha256 off GitHub's `digest`, reads every uploaded asset's stored digest back before the index goes up, reads the index back too, and ends by running `check_latest.py`. `DRY_RUN=1` prints and uploads nothing. Sets `--latest` only on `catalog-v0`. **It cannot publish a correction, and refuses by name rather than skipping** - see docs/RELEASING.md §5. |
| `check_latest.py` | the release marked Latest must be the one carrying `index-v0.json`, because that is the single URL every client compiles in. `publish_release.sh` runs it as its last step; run it by hand after any release you cut without that script. |
| `unreleased.sh` | what is committed here but not yet served. By hand only - never a CI job, and never a gate: exit 0 even when the answer is "unpublished", 2 only when it could not measure. |
| `diskinfo.py` | the single source of image facts: bootability, CBIOS banner, directory contents |

## Snapshots are carried only when the manifest says so

`fetch_romwbw.sh` refuses an upstream tag that is not a plain `vX.Y.Z` **unless
that version has declared itself** with `"prerelease": true` in
`versions/<ver>/version.json`. It also refuses a version that declares itself
while GitHub calls the tag a full release, so the flag cannot be left on by
mistake. The decision is per-version and committed, not an environment variable.

Carrying one means accepting a hazard that has not gone away:

- a snapshot's HCB carries the same two version bytes as the release it
  precedes. Measured on the real artifact: `v3.7.0-dev.14` reads `57 a8 37 00`,
  exactly what a released 3.7.0 will read. No version-byte check can tell them
  apart, including the one every client uses to validate a ROM.
- RomWBW's CBIOS compares major.minor only, so a snapshot disk booted against a
  release ROM of the same major.minor prints **no** mismatch warning.
- upstream can change anything before the release ships, and this repo's
  per-version tags are immutable once published.

What contains it:

- the version directory is named for the **full upstream tag**
  (`versions/3.7.0-dev.14/`), so every asset name and the release tag carry the
  suffix and cannot collide with a real 3.7.0 when it ships;
- the CBIOS banner is the one thing that separates them - `CBIOS v3.7.0-dev.14
  [WBW]` against `CBIOS v3.7.0 [WBW]` - and `boot_test.sh` asserts both that the
  disk carries it and that the ROM does **not**;
- `prerelease: true` reaches the index and the catalog, and
  `check_committed.py` and `verify_catalog.py` each refuse it on the `default`
  entry, so a snapshot can never be what a client picks on its own;
- clients hide it behind an opt-in - `docs/CATALOG_SCHEMA.md` §2.3.1.

`romwbw_emu` has one of these mistaken for a build input:
`archive/romwbw-v3.6.0/SBC_simh_std_v360.rom` is a `v3.6.0-dev.46` snapshot -
which is what the confusion looks like when nothing labels it.

`ALLOW_PRERELEASE=1` still builds a snapshot this repo does NOT carry, locally,
with a warning. Do not publish that.

Run `tools/check_upstream.sh` to see where things stand.

## Where `cpm_disk.py` went

It used to be vendored here, and this file called this copy "the canonical
one". It was the opposite: nothing in this repository ever called it — the
published images all start life as stock upstream images, so `cpmcp` was
enough — while `cpmemu`'s copy is the one `cpmemu/src/makefile:207` installs as
`cpm_disk` and the one the separate
[mpm2](https://github.com/avwohl/mpm2) repo drives through its `$CPM_DISK`
variable. The copy with no consumers claimed ownership over the copy with two.

So it is gone from here and `cpmemu/util/cpm_disk.py` is the only one. If this
repository ever needs it — for building an image this project defines rather
than adapts, which is the case `cpmcp` cannot cover — call it out of a sibling
checkout the way `check_source_drift.sh` already reaches for `romwbw_emu`,
rather than taking a copy.

The two copies were byte-identical right up to the day they were not: a bug
fixed in `cpmemu` (`ComboDisk` addressed file data 16384 bytes before the block
numbers said, so reading any file out of a combo image returned a neighbouring
file's bytes) would have had to be applied here by hand, and nothing compared
them. `check_source_drift.sh` covers the three Z80 sources - `r8.asm`,
`w8.asm` and `emu_hbios.asm`; it never covered this file.
