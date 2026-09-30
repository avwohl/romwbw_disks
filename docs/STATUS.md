# Status

The state of the published releases and of the boot testing. Back to the [README](../README.md).

## Compile-time allowlists are gone

The README says: adding a RomWBW release, a ROM or a disk image is a release in
this repo, not a new build of four clients.

That last sentence was an aspiration until 2026-09-17. Every client, and the
emulator core underneath them, carried a compile-time allowlist of RomWBW
releases, so publishing a new one here reached nobody until Windows, macOS,
iOS, Android and Linux had all been rebuilt. `romwbw_emu` v1.44 deleted the
core's list, and all three GUI clients dropped theirs the same day. What stands
in its place is `tools/boot_test.sh` and the rule that a release enters
`index-v0.json` only after it passes — see
[docs/INTERFACE_V0.md](INTERFACE_V0.md).

## Published releases

Both published releases are `stable`, and the index flags one of them
`default: true` — a fresh client lands there.

A client offers every release the index lists. It does not screen them on its
core's behalf: the emulator reads the RomWBW version out of the loaded ROM
(`romwbw_emu` v1.39 onward) and since v1.44 refuses no release at all, so one
binary boots whatever is published. The `hbios.ver_byte` and `hbios.upd_byte`
in every entry keep the job they always had — they pair a ROM with the disk
images that match it, which is the axis the guest's own
`HBIOS/CBIOS Version Mismatch` warning is about. A client that still bundles
one ROM uses them for exactly that.

Binaries built before 2026-09-17 filter the index by release and see only the
version they were built for; that is a property of those builds, not of the
catalog, and rebuilding is the whole of the fix.

Every release published here is booted by `tools/boot_test.sh`, and since
2026-09-18 that means all six operating systems on the images rather than the
CP/M 2.2 path alone. Per release it asserts the `CBIOS v<ver> [WBW]` banner, the
CP/M prompt, the release the emulator reports back from the ROM, a mismatched
pair warning in both directions, the `R8`/`W8` round trip, and then: ZSDOS,
NZCOM, banked CP/M 3, ZPM3 and Z3PLUS each boot and print what only they print.
CP/M 3's banner reads `CP/M v3.0 [BANKED] for HBIOS v<ver>`, so that one
assertion covers the banked path and the ROM-to-image pairing together. NZCOM is
checked by behaviour rather than by a banner - its slice's volume label differs
between releases, so the test asks the booted system for `PATH` and requires
ZCPR3's `No File` rather than the stock CCP's `PATH?`. The loader's
`NV Switches Found` is asserted too: that is the NVRAM checksum seed agreeing
with the ROM's own SYSCONF. Those five were checked once by hand on 2026-09-05
and by nothing between then and now.

The source-level question is no longer open in the way that sentence used to
say. 3.6.0's `Source/HBIOS/hbios.asm` *has* been read against the functions the
emulator's dispatcher implements — 2026-09-05, and a second pass checked all 82
implemented functions against RomWBW's own handlers; both are recorded in
[docs/FINDINGS.md](FINDINGS.md) section 11. No function changed contract
between 3.5.1 and 3.6.0; what the read found was a dispatcher answering six
questions wrongly all along, five of which 3.6.0 newly made reachable — the
sixth, `BF_CIOQUERY`, was reachable on 3.5.1 too, through `MODE.COM` on the
published images. All are fixed in `romwbw_emu`. What is still unread is the rest
of that 268 KB file, which is `romwbw_emu`'s to read, as the fixes were.
