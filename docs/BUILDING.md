# Building

How the ROMs and disk images are built, how `tools/boot_test.sh` proves them, and the source layout. Back to the [README](../README.md).

## The build

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
[docs/INTERFACE_V0.md](INTERFACE_V0.md) and
[docs/RELEASING.md](RELEASING.md) §5.

## Layout

```
src/        Z80 sources: w8.asm, r8.asm, emu_hbios.asm
tools/      the build and verify pipeline
versions/   one directory per RomWBW release: version, roms, disks, generation
catalog/    the generated catalogs, committed so changes show up in a diff
help/       the in-app help topics, published on the help-v0 tag
docs/       the documents listed in the README
build/      output (gitignored)
```

The RomWBW version is not written in the assembly. `tools/build_rom.sh`
generates `romwbw_ver.inc` from `versions/<ver>/version.json`, and
`emu_hbios.asm` includes it, because um80 cannot `#include` a C header.
`romwbw_emu` kept two hand-copied `db 035h` pairs until v1.44, which
parameterised its copy through a `romwbw_ver.inc` of its own — generated from
the HCB of the stock ROM it overlays. The file is byte-identical in both trees
now, and `tools/check_source_drift.sh` asserts exactly that.
