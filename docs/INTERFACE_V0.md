# Interface v0

`v0` is the contract between this repository and the emulator clients
(iOSCPM, CPMDroid, Z80CPMW, romwbw_emu). A client is *built for* an interface
version; it *chooses* a RomWBW version at runtime.

Those are two different axes, and conflating them is the problem this repo
exists to fix. Before it, there was one version string — a GitHub release tag
compiled into each client — and it was doing three jobs at once: naming the
disk images, naming the host-transfer ABI generation inside those images, and
implying which RomWBW release the client's bundled ROM matched. Adding a
RomWBW release meant a new build of every client, and publishing a new disk
image meant the same.

## What v0 covers

The interface version pins three things together. A change to any of them
that an existing client cannot tolerate is what bumps `v0` to `v1`.

**1. The catalog shape.** The `index-v0.json` and `catalog-v0-<ver>.json`
documents, their field names, and their meanings. Documented in
[CATALOG_SCHEMA.md](CATALOG_SCHEMA.md).

**2. The asset naming convention.** `<id>-v0-<romwbw-version>.<ext>`, on a
release tag named `v0-romwbw-<romwbw-version>`. Every asset on a version tag
carries both versions in its name, so a client can hold two RomWBW generations
in one flat download directory without collision — which none of them can do
today. The one exception is the entry point: `index-v0.json`, on the
`catalog-v0` tag, spans every RomWBW version and so carries only the interface
version.

**3. The HBIOS host-extension ABI.** The private function block the CP/M-side
helpers `W8.COM` and `R8.COM` call, which RomWBW itself knows nothing about,
is `0xE1`–`0xEA`. Two standard RomWBW functions are listed alongside it below
because the emulator's dispatcher handles them on the same path, and because
`HBF_SYSVER` is what a guest CBIOS compares its own version against:

| Function | Code | Purpose |
|---|---|---|
| `HBF_EXT` / `HBF_EXTSLICE` | `0xE0` | extended slice access — **standard RomWBW** (`BF_EXTSLICE` in upstream `Source/HBIOS/hbios.inc`), not part of the private block |
| `HBF_HOST_OPEN_R` | `0xE1` | open a host file for reading |
| `HBF_HOST_OPEN_W` | `0xE2` | open a host file for writing |
| `HBF_HOST_READ` | `0xE3` | read a byte from the open host file |
| `HBF_HOST_WRITE` | `0xE4` | write a byte to the open host file |
| `HBF_HOST_CLOSE` | `0xE5` | close the open host file |
| `HBF_HOST_MODE` | `0xE6` | get or set transfer mode |
| `HBF_HOST_GETARG` | `0xE7` | fetch a host-supplied command-line argument |
| `HBF_HOST_GETNAME` | `0xE8` | fetch the effective host write path |
| `HBF_HOST_CAPS` | `0xE9` | capability bitmask (see below) |
| `HBF_HOST_GETRNAME` | `0xEA` | fetch the effective host read path |
| `HBF_SYSVER` | `0xF1` | RomWBW version the emulator reports — **standard RomWBW** (`BF_SYSVER`), not part of the private block |

Those names and codes are the emulator's, from
`romwbw_emu/src/hbios_dispatch.h:131-179`. Of the private block, `W8.COM` uses
`0xE2`, `0xE4`, `0xE5`, `0xE8` and `0xE9`, and `R8.COM` uses `0xE1`, `0xE3`,
`0xE5` and `0xEA`; `0xE6` and `0xE7` are there for other guest programs.

A guest loads `B` with the function number and executes `RST 08`. The page-zero
vector jumps to the bank-0 proxy at `0xFFF0` (`src/emu_hbios.asm:64-66`), which
does `OUT (0xEF),A` — and that `OUT` is what the emulator traps
(`romwbw_emu/src/hbios_cpu.cc:125`). The emulator also uses `0xEC` for bank
copy, `0xED` for bank call and `0xEE` for signalling
(`src/emu_hbios.asm:45-48`, `romwbw_emu/src/hbios_cpu.cc:71,106,120`).
`HOST_PATH_MAX` is 256 (`romwbw_emu/src/hbios_dispatch.h:210`).

### Capabilities, not a version number, inside the ABI

Within v0 the ABI grew by accretion — `0xE8`, then `0xE9`, then `0xEA` — and
compatibility is negotiated per call: an emulator that predates a function
answers with `A` nonzero from its unknown-function path. Do not test for a
specific value there. Unknown functions in `0xE0`–`0xEF` reach
`HBIOSDispatch::handleEXT`, whose default arm sets `HBR_NOFUNC`
(`romwbw_emu/src/hbios_dispatch.cc:2718`), and `HBR_NOFUNC` is `-3`
(`romwbw_emu/src/hbios_dispatch.h:30`), so it arrives in `A` as `0xFD`, not
`0xFF`. `0xFF` is a *different* answer: it is `HBR_FAILED`, which `0xE8` and
`0xEA` also return when the call exists but no file is open. Both are nonzero,
which is exactly why the guest tests only for nonzero. The one real negotiation
is `HBF_HOST_CAPS`:

    EMU_HOST_CAP_SAFE_PATHS = 0x01   a guest path is never used destructively

(`romwbw_emu/src/emu_io.h:452`.) `W8.COM` probes it before it hands a host path
to the emulator and refuses if the bit is clear — and it refuses on `A <> 0`
first, whatever the nonzero value (`src/w8.asm:344-350`). The probe assembles to
three bytes, `06 E9 CF` (`ld b,0E9h` / `rst 8`). `tools/build_utils.sh` asserts
those exact bytes are in the freshly linked `w8.com` and refuses to continue
otherwise, and `tools/verify_catalog.py` re-asserts them for every published
image whose catalog entry claims `host_transfer` — today only `hd1k_combo`,
in both published versions. The verifier reads the `w8.com` out of the
image's CP/M directory and searches *that*, not the whole image: three bytes
turn up somewhere in 51 MB by chance, so an image-wide search would pass on a
`w8.com` that had lost the probe entirely. That check catches something no hash
can: a `.COM` that is syntactically valid and semantically obsolete.

Keep that pattern. A capability bit says what an implementation *does*; a
version number says what it *claims*. On the host side the same discipline is
enforced by leaving `emu_host_path_caps()` declared but undefined in
`emu_io.h` (`romwbw_emu/src/emu_io.h:454`), so a port that has not implemented
it fails to **link** rather than silently asserting a guarantee it does not
make.

## What v0 does not cover

**The RomWBW version.** That is data in the catalog, not part of the contract.
Adding RomWBW 3.7.0 is a new release tag and a regenerated index — no client
change, no interface bump.

**Disk contents.** Adding, removing or rebuilding an image advances that
version's `generation` counter and nothing else.

**Client app versions.** iOS `MARKETING_VERSION`, Android `versionName`,
Windows `VERSION_STRING` are unrelated and stay unrelated.

## The one thing v0 could not fix on its own — now fixed upstream

A client could *fetch* two RomWBW versions and run only one.

`emu_validate_rom_hcb` in `romwbw_emu/src/emu_init.cc` compared the loaded
ROM's HCB bytes at `0x105`/`0x106` against the compile-time
`ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` from `src/romwbw_pin.h` and
returned a refusal that `emu_load_rom` turned into a failed load. With
`ROMWBW_PIN_STR` at `"3.5.1"`, the binary physically could not load a 3.6.0
ROM.

**As of `romwbw_emu` v1.39 the version is runtime state read from the loaded
ROM.** One binary boots any release in that core's `ROMWBW_SUPPORTED_RELEASES`
— today both of the ones published here — and the five sites that report a
version to the guest all derive it from the ROM: `HBF_SYSVER`, the NVRAM
checksum seed, the HBIOS ident block, the CBIOS page-zero stamp at
`0x42`/`0x43`, and the load-time check. What that check now refuses is a
release the core has never been *run* against, which is a different and much
narrower thing.

None of that changed v0. The catalog was designed for it — `hbios.ver_byte` /
`upd_byte` are in every index entry precisely so a client can filter without
downloading anything — and those fields keep their meaning. A client that
filters is still correct; a client that offers the whole list is now also
correct, and gets a version it can actually boot. Adding the capability to the
emulator is not an interface change, which is exactly what
[the compatibility rules](#when-to-bump-to-v1) predict: nothing was removed,
repurposed or renamed in the catalog.

What still gates the user-visible feature is client work, not emulator work:
iOS, Android and Windows all ship a binary built before v1.39.
[CLIENT_MIGRATION.md](CLIENT_MIGRATION.md) lists what each has to change.

## When to bump to v1

Bump when an existing client would misbehave rather than merely miss out:

- removing or repurposing a catalog field a client reads
- changing the asset naming convention
- a breaking change to the `0xE1`–`0xEA` ABI (adding a function is not one;
  the unknown-function path already handles it, and a new capability bit is
  how a caller finds out)
- changing what `HBF_HOST_CAPS` bit 0 promises

Adding an optional field, a RomWBW version, a ROM, or a disk is **not** a bump.

A v1 lives alongside v0: new release tags, a new index URL, and the v0 tags
untouched. GitHub release asset URLs cannot be redirected, so every tag this
repo publishes has to stay live for as long as any client points at it.
