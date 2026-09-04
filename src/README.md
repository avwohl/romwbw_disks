# Z80 sources

The CP/M- and ROM-side code this repo builds. These moved here from
`romwbw_emu/src`; that is now the wrong home for them, because the artifacts
they produce are published from here.

| File | What it is |
|---|---|
| `w8.asm` | `W8.COM` — writes a CP/M file out to the host. Probes `HBF_HOST_CAPS` and refuses to hand over a host path unless `CAP_SAFE_PATHS` is set. |
| `r8.asm` | `R8.COM` — reads a host file into CP/M. |
| `emu_hbios.asm` | Bank 0 of every emulator ROM: a minimal HBIOS that dispatches through `OUT (0xEF),A` instead of touching hardware. |
| `emu_rom.asm` | A standalone boot ROM. Nothing builds it today; kept because it is the only record of that path. |

## The version bytes

`emu_hbios.asm` does not name a RomWBW version. It does
`include romwbw_ver.inc`, and `tools/build_rom.sh` generates that file from
`versions/<ver>/version.json` into a scratch directory before assembling. So
one source builds a ROM for any RomWBW release, and the two places the version
appears — the HCB at `0x105`/`0x106` and the proxy ident block at `0xFE02` —
cannot drift from each other or from the published catalog.

In `romwbw_emu` these were two hand-copied `db 035h` pairs, kept in step with
`src/romwbw_pin.h` by `roms/verify_romwbw_pin.sh`, because um80 cannot
`#include` a C header. It can `include` an assembly file, which is what this
uses.

## Do not remove the duplicate ident pointer

`emu_hbios.asm` writes `dw HBX_LOC` at **both** `0xFFFC` and `0xFFFE`. That is
deliberate. Upstream moved `HB_IDENT` from `HBX_XFCFNS + 14` (`0xFFFE`) to
`HBX_XFCFNS + 12` (`0xFFFC`) in RomWBW 3.6.0, and writing both is what lets one
proxy serve both releases. A guest built against the other release would read a
zero and follow it.

The comment on the second one used to say "Reserved". It was wrong, and it is
corrected in this copy.

## Building

`w8.com` and `r8.com` belong to the interface version, not to any RomWBW
release — they call the emulator's private HBIOS extension block, which RomWBW
knows nothing about. One build serves every version:

```sh
tools/build_utils.sh          # -> build/utils/{w8,r8}.com
tools/build_rom.sh 3.5.1      # -> build/v0-romwbw-3.5.1/*.rom
```

Both need `um80` and `ul80` (`pip install um80`).

Neither `w8.asm` nor `r8.asm` has an `ORG`. `ul80` bases a `.COM` at `0100h`
itself; an `ORG` on top of that leaves 256 leading NOPs.
