# tools

The build and verify pipeline. Run `build_all.sh`; everything else is a stage
of it or a check on it.

| Script | Does |
|---|---|
| `common.sh` | shared settings, sourced not run. Owns `IFACE`, the asset-naming and release-tag functions, and the toolchain check. |
| `check_upstream.sh` | asks GitHub which RomWBW releases exist, which are carried here, and which are prereleases |
| `fetch_romwbw.sh` | downloads an upstream `Package.zip`, pins it by sha256 in `versions/<ver>/version.json`, extracts only the build inputs. Refuses a prerelease tag. |
| `build_utils.sh` | assembles `w8.com` and `r8.com`, and asserts `w8.com` still carries the `06 e9 cf` capability interlock |
| `build_rom.sh` | generates `romwbw_ver.inc`, assembles bank 0, overlays banks 1–15 from a stock ROM, verifies the HCB |
| `build_disks.sh` | copies the stock images, injects `w8`/`r8` where the manifest says, verifies each CBIOS banner |
| `gen_catalog.py` | writes the catalogs and the index from the built artifacts — every size and hash computed, none transcribed |
| `verify_catalog.py` | re-derives every claim a catalog makes, independently of the generator. Works on downloaded assets too. |
| `verify_release.sh` | runs `verify_catalog.py` across every version and the index |
| `check_source_drift.sh` | do this repo's Z80 sources still agree with romwbw_emu's? Three must be byte-identical; `emu_hbios.asm` must differ only by its generated `romwbw_ver.inc` parameterisation, which is proved by both trees building the same `emu_avw.rom`. Skips when romwbw_emu is not beside this repo. |
| `boot_test.sh` | asks romwbw_emu which RomWBW releases it can run, then holds it to that answer: each one it can run must boot to a CP/M prompt with the right `CBIOS v<ver> [WBW]` banner and no mismatch warning, report the release it read from the ROM, warn on a disk from another release, and round-trip a file through `R8`/`W8`; each one it cannot must be refused by name. Skips when no emulator is present. |
| `diskinfo.py` | the single source of image facts: bootability, CBIOS banner, directory contents |
| `diskdefs` | cpmtools definitions, including the `wbw_hd1k_0..5` combo slices no distribution ships |

## Releases only, never snapshots

`fetch_romwbw.sh` refuses an upstream tag that is not a plain `vX.Y.Z`, and
refuses one GitHub marks as a prerelease. Upstream tags development snapshots
alongside releases — `v3.7.0-dev.13` sits above `v3.6.0` on the releases page —
and they are not publishable from here:

- a snapshot's HCB carries the same two version bytes as the release it
  precedes: `v3.7.0-dev.13` reads `37 00`, exactly as a released 3.7.0 would.
  No version-byte check can tell them apart.
- RomWBW's CBIOS compares major.minor only, so a snapshot disk booted against a
  release ROM of the same major.minor prints **no** mismatch warning.
- upstream can change anything before the release ships, and this repo's
  per-version tags are immutable once published.

`romwbw_emu` already has one of these mistaken for a build input:
`archive/romwbw-v3.6.0/SBC_simh_std_v360.rom` is a `v3.6.0-dev.46` snapshot.

`ALLOW_PRERELEASE=1` builds one locally anyway, with a warning. Do not publish
the result.

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
them. `check_source_drift.sh` covers `r8.asm`, `w8.asm` and `emu_rom.asm`; it
never covered this file.

## Why `diskdefs` is here

cpmtools reads `./diskdefs` if there is one and the system file otherwise, and
no distribution's system file carries the combo slice definitions. So every
cpmtools call in `build_disks.sh` runs with `tools/` as its working directory
and passes absolute image paths.

A wrong diskdef does not fail loudly: cpmtools reads a garbage directory and
`cpmcp` writes at the wrong offset while reporting success. That is why
`build_disks.sh` checks each image's size against the shape its diskdef implies
before writing anything into it.
