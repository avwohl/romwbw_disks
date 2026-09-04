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
release tag named `v0-romwbw-<romwbw-version>`. Every published filename
carries both versions, so a client can hold two RomWBW generations in one flat
download directory without collision — which none of them can do today.

**3. The HBIOS host-extension ABI.** The private function block the CP/M-side
helpers `W8.COM` and `R8.COM` call, which RomWBW itself knows nothing about:

| Function | Code | Purpose |
|---|---|---|
| `HBF_EXT` / `HBF_EXTSLICE` | `0xE0` | extended slice access |
| `HBF_HOST_OPEN_R` | `0xE1` | open a host file for reading |
| `HBF_HOST_OPEN_W` | `0xE2` | open a host file for writing |
| `HBF_HOST_READ` | `0xE3` | read from the open host file |
| `HBF_HOST_WRITE` | `0xE4` | write to the open host file |
| `HBF_HOST_CLOSE` | `0xE5` | close the open host file |
| `HBF_HOST_MODE` | `0xE6` | set transfer mode |
| `HBF_HOST_GETARG` | `0xE7` | fetch a host-supplied argument |
| `HBF_HOST_GETNAME` | `0xE8` | fetch the host-supplied filename |
| `HBF_HOST_CAPS` | `0xE9` | capability bitmask (see below) |
| `HBF_HOST_GETRNAME` | `0xEA` | fetch the host-supplied read filename |
| `HBF_SYSVER` | `0xF1` | RomWBW version the emulator reports |

Dispatch is `OUT (0xEF),A` after loading `B` with the function number; the
emulator also uses `0xEC` for bank copy, `0xED` for bank call and `0xEE` for
signalling. `HOST_PATH_MAX` is 256.

### Capabilities, not a version number, inside the ABI

Within v0 the ABI grew by accretion — `0xE8`, then `0xE9`, then `0xEA` — and
compatibility is negotiated per call: an emulator that predates a function
answers `A = 0xFF` from its unknown-function path. The one real negotiation is
`HBF_HOST_CAPS`:

    EMU_HOST_CAP_SAFE_PATHS = 0x01   a guest path is never used destructively

`W8.COM` probes it before it hands a host path to the emulator and refuses if
the bit is clear. The probe assembles to three bytes, `06 E9 CF`
(`ld b,0E9h` / `rst 8`), and both `tools/build_utils.sh` and
`tools/verify_catalog.py` assert those bytes are present in every published
`w8.com`. That check catches something no hash can: a `.COM` that is
syntactically valid and semantically obsolete.

Keep that pattern. A capability bit says what an implementation *does*; a
version number says what it *claims*. On the host side the same discipline is
enforced by leaving `emu_host_path_caps()` declared but undefined in
`emu_io.h`, so a port that has not implemented it fails to **link** rather than
silently asserting a guarantee it does not make.

## What v0 does not cover

**The RomWBW version.** That is data in the catalog, not part of the contract.
Adding RomWBW 3.7.0 is a new release tag and a regenerated index — no client
change, no interface bump.

**Disk contents.** Adding, removing or rebuilding an image advances that
version's `generation` counter and nothing else.

**Client app versions.** iOS `MARKETING_VERSION`, Android `versionName`,
Windows `VERSION_STRING` are unrelated and stay unrelated.

## The one thing v0 cannot fix on its own

A client can *fetch* two RomWBW versions today. It cannot *run* both.

`emu_validate_rom_hcb` in `romwbw_emu/src/emu_init.cc:52-60` compares the
loaded ROM's HCB bytes at `0x105`/`0x106` against the compile-time
`ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` from `src/romwbw_pin.h`, and
returns a refusal that `emu_load_rom` turns into a failed load. A binary
pinned to 3.5.1 physically cannot load a 3.6.0 ROM.

So until `romwbw_emu` makes the pin runtime state read from the loaded ROM,
"pick a RomWBW version" means "the client filters the index down to the one
version it was built for". The catalog is designed for the eventual runtime
pin — `hbios.ver_byte` / `upd_byte` are in every index entry precisely so a
client can filter without downloading anything — but the emulator change is
what turns filtering into choosing. [CLIENT_MIGRATION.md](CLIENT_MIGRATION.md)
lists what that change touches.

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
