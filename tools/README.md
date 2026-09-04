# tools

The build and verify pipeline. Run `build_all.sh`; everything else is a stage
of it or a check on it.

| Script | Does |
|---|---|
| `common.sh` | shared settings, sourced not run. Owns `IFACE`, the asset-naming and release-tag functions, and the toolchain check. |
| `fetch_romwbw.sh` | downloads an upstream `Package.zip`, pins it by sha256 in `versions/<ver>/version.json`, extracts only the build inputs |
| `build_utils.sh` | assembles `w8.com` and `r8.com`, and asserts `w8.com` still carries the `06 e9 cf` capability interlock |
| `build_rom.sh` | generates `romwbw_ver.inc`, assembles bank 0, overlays banks 1–15 from a stock ROM, verifies the HCB |
| `build_disks.sh` | copies the stock images, injects `w8`/`r8` where the manifest says, verifies each CBIOS banner |
| `gen_catalog.py` | writes the catalogs and the index from the built artifacts — every size and hash computed, none transcribed |
| `verify_catalog.py` | re-derives every claim a catalog makes, independently of the generator. Works on downloaded assets too. |
| `verify_release.sh` | runs `verify_catalog.py` across every version and the index |
| `boot_test.sh` | actually boots the artifacts in romwbw_emu and asserts the version guards fire. Skips when no emulator is present. |
| `diskinfo.py` | the single source of image facts: bootability, CBIOS banner, directory contents |
| `cpm_disk.py` | CP/M image creation and file transfer for sssd, hd1k and combo formats |
| `diskdefs` | cpmtools definitions, including the `wbw_hd1k_0..5` combo slices no distribution ships |

## Why `cpm_disk.py` is here

It is the family's only tool that can *create* an hd1k or combo image from
nothing. It came from `cpmemu/util/cpm_disk.py`, which is also what the
separate [mpm2](https://github.com/avwohl/mpm2) repo drives through its
`$CPM_DISK` variable in `scripts/build_hd1k.sh`.

This copy is the canonical one. `cpmemu`'s stays for now because
`cpmemu/src/makefile:207` installs it as `cpm_disk` and removing it would break
both that and mpm2. Point those at this copy before deleting the other.

Nothing in the current pipeline calls it — the published images all start life
as stock upstream images, so `cpmcp` is enough. It is here for the case that
does not: building an image this project defines rather than adapts.

## Why `diskdefs` is here

cpmtools reads `./diskdefs` if there is one and the system file otherwise, and
no distribution's system file carries the combo slice definitions. So every
cpmtools call in `build_disks.sh` runs with `tools/` as its working directory
and passes absolute image paths.

A wrong diskdef does not fail loudly: cpmtools reads a garbage directory and
`cpmcp` writes at the wrong offset while reporting success. That is why
`build_disks.sh` checks each image's size against the shape its diskdef implies
before writing anything into it.
