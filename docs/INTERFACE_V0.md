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
(`romwbw_emu/src/hbios_cpu.cc:135`). The emulator also uses `0xEC` for bank
copy, `0xED` for bank call and `0xEE` for signalling
(`src/emu_hbios.asm:45-48`, `romwbw_emu/src/hbios_cpu.cc:71,116,130`).
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
change, no interface bump. That sentence was written as a promise and was false
for as long as the emulator carried a release allowlist; it became true on
2026-09-17, and the section below is the record of how.

**Disk contents.** Adding, removing or rebuilding an image advances that
version's `generation` counter and nothing else.

**Client app versions.** iOS `MARKETING_VERSION`, Android `versionName`,
Windows `VERSION_STRING` are unrelated and stay unrelated.

## The one thing v0 could not fix on its own — fixed, 2026-09-17

A client could *fetch* two RomWBW versions and run only one. The fix took two
steps twelve days apart, and it is the second one that made the promise above
true.

**What it was.** `emu_validate_rom_hcb` in `romwbw_emu/src/emu_init.cc`
compared the loaded ROM's HCB bytes at `0x105`/`0x106` against the compile-time
`ROMWBW_PIN_VER_BYTE` / `ROMWBW_PIN_UPD_BYTE` from `src/romwbw_pin.h` and
returned a refusal that `emu_load_rom` turned into a failed load. With
`ROMWBW_PIN_STR` at `"3.5.1"`, the binary physically could not load a 3.6.0
ROM.

**`romwbw_emu` v1.39 (2026-09-05) made the version runtime state** read from
the loaded ROM. The five sites that report a version all derive it from the
ROM: `HBF_SYSVER`, the NVRAM checksum seed, the HBIOS ident block, the CBIOS
page-zero stamp at `0x42`/`0x43`, and the load-time check. What that check
still refused was a release missing from a hand-edited list,
`ROMWBW_SUPPORTED_RELEASES` — narrower than a single pin, and still a
compile-time allowlist adjudicating a number this repository writes.

**`romwbw_emu` v1.44 (2026-09-17) deleted the list, and `src/romwbw_pin.h`
with it.** A ROM whose HCB declares any release now loads.
`emu_validate_rom_hcb` keeps its name, its signature and its other jobs — the
size check, the `'W' 0xA8` marker at `0x103`, and the `CB_PLATFORM` warning —
and has no release branch at all. Checked rather than asserted: a ROM patched
to declare 3.7.0 loads and boots to the RomWBW boot loader; before it, that ROM
was refused. Gone with the list: `emu_romwbw_release_supported()`,
`emu_romwbw_supported_list()`, `--allow-untested-romwbw`, and the
`RomWBW releases this build can run:` line `romwbw_emu --version` printed.
What stayed is everything that reads a release rather than judging one —
`emu_romwbw_release_of_image()`, `emu_romwbw_release_loaded()` and
`emu_romwbw_release_str()`.

### A release number was never the axis this core depends on

A RomWBW release number is the **HBIOS-to-CBIOS pairing** — a fact about a ROM
and a disk image, enforced at boot by the guest itself printing
`*** WARNING: HBIOS/CBIOS Version Mismatch ***`. That warning comes from RomWBW,
not from us, and the catalog already serves it by naming both versions in every
filename.

What an emulator depends on is the **emulator-to-ROM interface**: the two I/O
ports the bank-0 proxy uses and the set of HBIOS functions
`romwbw_emu/src/hbios_dispatch.cc` services. That interface is versioned by
this catalog's own name. **Every release a v0 index publishes speaks v0** —
publishing it here is the assertion that it does, as the next section says —
and an interface change the core could not service is published as
`index-v1.json` beside `index-v0.json`, which a v0 client ignores by name.

So the gate already existed, one level up, and it is per-generation and costs
no application build. The release allowlist was a second, finer, weaker gate on
the wrong axis: it could only ever hide a release the user could in fact have
booted, and its price was an application release per RomWBW version — the exact
coupling this interface exists to remove.
`romwbw_emu/docs/RELEASE_GATE.md` is the long-form argument.

### Publishing into the v0 index is the assertion that it boots

The allowlist was standing in for something real, and what replaced it is a
measurement rather than another list.

v0's third pillar covers the private `0xE1`–`0xEA` block and the two standard
functions beside it. It does **not** enumerate the standard RomWBW HBIOS
functions the dispatcher implements, so a future release whose CBIOS called a
standard function the dispatcher lacks would not be caught by v0 as written.

`tools/boot_test.sh` is what catches it, and running it before a release is
published is required rather than advised — [RELEASING.md](RELEASING.md) §4
and §5, and the §8 checklist. It boots the exact ROM and disk image being
published and asserts the CBIOS banner, the CP/M prompt, no mismatch warning
on a matched pair, the warning on a mismatched one, and an `R8`/`W8` round
trip through the private block. It has no refusal branch and parses no
`--version` banner: a ROM that does not boot is a failure, never a correct
refusal.

**An entry in a v0 index therefore carries a promise**: this repository booted
that release against the emulator before publishing it. That is weaker in
principle than "somebody booted *your* binary against it" and stronger in
practice — the compile-time list was edited months before the release it
blessed and never re-checked, while `boot_test.sh` runs at the moment the
decision is made, against the artifact the decision is about.

### What the version bytes are still for

None of this changed v0, and `hbios.ver_byte` / `hbios.upd_byte` stay in every
index entry, documented and unmoved. What changed is what they are *for*.

They are the ROM-to-disk-image pairing, readable before anything is downloaded.
A client holding a 3.6.0 ROM can still use them to decline a 3.5.1 image — that
is the mismatch warning's own axis, and it is a real thing to protect a user
from. What they never were, though they were used as one, is a statement about
what an emulator build can run.

A client that still filters the index by release is reading a field that means
what it always meant; it is merely hiding releases it could boot. All three GUI
clients dropped that filter on 2026-09-17 — z80cpmw `3c64be7`, ioscpm
`ed660d5`, cpmdroid `c46b01b` — the same day `romwbw_emu` released the core
change as v1.44.

**Publishing a new RomWBW release is now a release tag and a regenerated index
here, and nothing in `romwbw_emu`, `z80cpmw`, `ioscpm` or `cpmdroid`.** One
caveat, and it is a property of shipped binaries rather than of the contract: a
client binary built before 2026-09-17 still filters, and will still hide a new
release from its user until it is rebuilt. Nothing published here reaches it.
[CLIENT_MIGRATION.md](CLIENT_MIGRATION.md) records what each client changed.

## When to bump to v1

Bump when an existing client would misbehave rather than merely miss out:

- removing or repurposing a catalog field a client reads
- changing the asset naming convention
- a breaking change to the `0xE1`–`0xEA` ABI (adding a function is not one;
  the unknown-function path already handles it, and a new capability bit is
  how a caller finds out)
- changing what `HBF_HOST_CAPS` bit 0 promises

Adding an optional field, a RomWBW version, a ROM, or a disk is **not** a bump.

Neither is anything in the section above. No field was removed, repurposed or
renamed; what changed is what a consumer *does* with two fields that still mean
what they meant, which v0 never constrained. The allowlist going away made v0's
promise true — it did not put a bump in prospect.

A v1 lives alongside v0 **on the release marked Latest**: `index-v1.json` beside
`index-v0.json`, and the v0 tags untouched. v0 clients keep reading v0, v1
clients read v1, and neither is rebuilt for the other's sake.

This paragraph used to say "new release tags, **a new index URL**", and that was
the plan's undoing: a new index URL is unreachable from a client with the old one
compiled in, so the migration it described silently required releasing Windows,
Android, iOS and Linux at once - the coupling this whole interface exists to
remove. Every client now compiles in
`releases/latest/download/index-v0.json`, which names no tag, so where the index
lives is this repository's to change. See CATALOG_SCHEMA.md §6.2 for the
invariant that buys and the one flag that breaks it.

GitHub release asset URLs cannot be redirected, so every tag this repo publishes
has to stay live for as long as any client points at it - and every client built
before 2026-09-10 points at `catalog-v0` by name, whatever is done from here.
