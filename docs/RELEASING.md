# Releasing

How to build the artifacts in this repository and how to publish them. Read
[INTERFACE_V0.md](INTERFACE_V0.md) first for what the `v0` contract promises;
this document is only about turning a checkout into a set of GitHub release
assets and not breaking anything that already points at one.

Two things get published, and they are published differently:

| What | Tag | Mutable? | Size |
|---|---|---|---|
| ROMs, disk images, `catalog-v0-<ver>.json`, `disks-v0-<ver>.xml` | `v0-romwbw-<ver>` | **No.** Immutable once a client has shipped against it — see section 5. | 202 MB (3.5.1), 234 MB (3.6.0) |
| `index-v0.json` | `catalog-v0` | Yes. Re-cut whenever the set of versions changes. | 2942 bytes |

Section 4 explains why the split exists.

## 1. Prerequisites

| Tool | Install | Needed for |
|---|---|---|
| `um80`, `ul80` | `pip install um80` | assembling `src/*.asm` |
| `cpmcp`, `cpmrm`, `cpmls` | `brew install cpmtools` / `apt install cpmtools` | writing W8/R8 into CP/M directories |
| `python3` | system | catalog generation and verification |
| `curl`, `unzip` | system | fetching upstream RomWBW packages |
| `gh` | `brew install gh` / <https://cli.github.com> | publishing only, not building |

Everything Python is standard library. There is no `requirements.txt` and no
virtualenv to set up beyond `um80`.

`need_tools` (`tools/common.sh:48`) prints the install line for anything not on
`PATH`, and each stage calls it for what that stage needs: `um80`/`ul80` in
`tools/build_utils.sh:20` and `tools/build_rom.sh:23`, `cpmcp`/`cpmrm`/`cpmls` in
`tools/build_disks.sh:24`, `gh` in `tools/publish_release.sh`. So a missing
assembler fails in the first second. It is not a blanket preflight: `curl`,
`unzip` and `python3` are never passed to it and fail at the point of use, and
cpmtools is not checked until stage 4 — after the download — so on a fresh
machine it is worth confirming all of them by hand before starting a 440 MB
build.

You do **not** need to install a `diskdefs` file system-wide. cpmtools reads
`./diskdefs` in preference to the system copy, and no distribution's system copy
carries RomWBW's combo slice definitions, so `tools/build_disks.sh` runs every
cpmtools call with the working directory set to `tools/` and passes absolute
image paths. That is what the `cpmtool()` wrapper in `tools/build_disks.sh` is
for.

`sha256sum` is used where it exists and `shasum -a 256` otherwise
(`tools/common.sh:28`), so macOS and Linux both work unmodified.

### um80 is deliberately unpinned, and that is the point

`um80` is a pip package from `github.com/avwohl/um80_and_friends`. Nothing in
this repository pins its version, and nothing should.

The reason is that the assembler's output is an *input to the reproducibility
claim*, not a detail underneath it. Bank 0 of every ROM and both host-transfer
utilities are whatever `um80` emits today. If a future `um80` emits different
bytes, the rebuild stops matching the published `sha256` and
`tools/verify_release.sh` goes red. That is the alarm working, not the alarm
malfunctioning. A pin would convert a real behaviour change into a silent
"nothing to see here" until someone bumped the pin.

This is not hypothetical. `um80` 0.3.42 assembled `add a,'a'-'A'` in `w8.asm` as
`add a,0`, and CPMDroid still carries a runtime hot-patch for it at
`cpmdroid/app/src/main/cpp/emu_io_android.cpp:1129-1147` — it scans every loaded
disk image for the bytes `fe 41 d8 fe 5b d0 c6 00` and pokes byte 7 to `0x20`.
The `w8.com` this repo builds contains the fixed sequence `fe41d8fe5bd0c620`, so
that patch is now dead code, and a liability: it would happily rewrite bytes
inside a v3.6.0 image it has never seen.

Because a hash alone cannot tell you a `.COM` is semantically wrong, the build
also asserts on meaning. `tools/build_utils.sh` refuses to ship a `w8.com` that
does not contain `06 e9 cf` — `ld b,0E9h` / `rst 8`, W8's `HBF_HOST_CAPS` probe —
and `tools/verify_catalog.py` re-asserts it on every published image. A `w8.com`
that assembles cleanly but has lost the probe would hand an old emulator an
unchecked host path, and no checksum comparison would notice.

Last reproduced with `um80`/`ul80` **0.3.46**. If your rebuild does not match,
check your version before you go looking for a build bug.

## 2. The full build

```sh
tools/build_all.sh              # every version in versions/
tools/build_all.sh 3.5.1        # one version
```

`tools/build_all.sh` runs `build_utils.sh` once, then `fetch_romwbw.sh`,
`build_rom.sh` and `build_disks.sh` per version, then `gen_catalog.py` over the
versions it was asked for, then `verify_release.sh`. It sets `-eu`, so any stage
failing stops the run. Note that `gen_catalog.py` regenerates only the catalogs
for the versions named on its command line (`build_all.sh:40` passes them
straight through), but always rewrites the index over every version in
`versions/`.

**Stage 1 — `tools/build_utils.sh`.** Assembles `src/w8.asm` and `src/r8.asm`
with `um80` to `.rel`, links with `ul80` to `build/utils/{w8,r8}.com`, 1792 bytes
each. Neither source has an `ORG`: `ul80` bases a `.COM` at `0100h` by itself and
an `ORG` on top of that produces 256 leading NOPs and a program that runs off the
end of its own code. Then it asserts the `06 e9 cf` interlock and deletes the
intermediate `.rel`/`.sym`. It takes no version argument, because W8 and R8 talk
to the emulator's `0xE1`–`0xEA` host-file block, which RomWBW knows nothing
about — they belong to the interface version, not to a RomWBW release, and one
build serves every release. Measured: 0.25 s.

**Stage 2 — `tools/fetch_romwbw.sh <ver>`.** Downloads the `Package.zip` named in
`versions/<ver>/version.json` into `$ROMWBW_CACHE/.romwbw-dl` with
`curl -fL --retry 3 --retry-delay 2 -C -` (the `-C -` matters: without it a
killed run leaves a truncated zip that `unzip` reports as corrupt rather than as
incomplete). It then hashes the archive. If `upstream.package_sha256` is empty it
records the hash into the manifest; if it is set and does not match, the script
dies and refuses to build. That is the whole of "pinning upstream". Then
`unzip -o -q -j` extracts only `Binary/SBC_simh_std.rom`, `Binary/RCZ80_std.rom`
and `Binary/hd1k_*.img`, because the full archive unpacks to about a gigabyte per
release and the build needs a fraction of it.

**Stage 3 — `tools/build_rom.sh <ver>`.** Copies `src/emu_hbios.asm` into a
scratch directory and writes `romwbw_ver.inc` next to it, generated from
`versions/<ver>/version.json` (`um80` resolves `include` relative to the working
directory, which is why they are assembled together in a scratch dir rather than
in place). Assembles, links flat at `0000`, pads to a full 32 KB bank 0. For each
entry in `versions/<ver>/roms.json` it then checks the *stock* upstream ROM's own
HCB bytes at file offset 261 against the manifest and that the file is exactly
524288 bytes, `dd`s bank 0 over bank 0 and stock banks 1–15 into a 512 KB output,
re-reads the built ROM's HCB at `0x103`, and **deletes the output** if it is not
`57 a8` followed by the two packed version bytes — rather than leave behind a ROM
that loads and dies.

The version is not written in the assembly. Before this repo it was two
hand-copied `db 035h` pairs in `emu_hbios.asm`, kept in step with
`romwbw_emu/src/romwbw_pin.h` by a separate verify script, because assembly
cannot `#include` a C header. Now one source builds a ROM for any release and the
copies cannot drift.

The stock-ROM HCB check is also the thing that stops a development snapshot being
used as banks 1–15. `romwbw_emu/archive/romwbw-v3.6.0/SBC_simh_std_v360.rom` is a
`v3.6.0-dev.46` build from 2025-12-12 whose HCB reads `36 00`, indistinguishable
from the real release. `fetch_romwbw.sh` never touches it; only the CBIOS banner
can tell the two apart, which is why the banner is checked at stage 4.

**Stage 4 — `tools/build_disks.sh <ver>`.** For each entry in
`versions/<ver>/disks.json`: copy the stock image, check its size against the
declared diskdef (`wbw_hd1k` must be exactly 8388608 bytes; `wbw_hd1k_N` must be a
1048576-byte prefix plus whole 8 MB slices) *before writing anything*, because a
wrong diskdef does not fail loudly — cpmtools reads a garbage directory and
`cpmcp` writes at the wrong offset while reporting success. Then `cpmrm` any
existing copy and `cpmcp` `w8.com` and `r8.com` onto the slices the manifest names,
confirming each one with `cpmls` rather than trusting an exit code (`cpmrm` exits 0
having removed nothing on an image it cannot write). Then `tools/diskinfo.py`
reports `bootable`, the CBIOS banner and which utilities are present.

Two conditions fail the image and delete it: any CBIOS banner in the slice that is
not exactly `CBIOS v<ver> [WBW]`, and a manifest that asked for W8/R8 where the
directory does not have them. The banner check is a whole-string match, not
major.minor, precisely so a `-dev.NN` banner fails too.

The only thing this repo adds to a stock image is `W8.COM` and `R8.COM`, and only
where `disks.json` says. The built `hd1k_combo` differs from the stock upstream
image in 8234 bytes across 24 runs — the same figure for 3.5.1 and for 3.6.0 —
all of it those two files and their two directory entries. That is the same
addition every shipped client already carries, though not the same bytes:
`romwbw_emu/disks/hd1k_combo.img` differs from this build in 14765 bytes across
217 runs. What *is* byte-identical is the `w8.com` and `r8.com` inside it — see
section 3.

**Stage 5 — `tools/gen_catalog.py [ver ...]`.** Computes every size and every
`sha256` from the file that will actually be uploaded. Nothing is transcribed. Per
version it writes `build/v0-romwbw-<ver>/catalog-v0-<ver>.json`, the legacy
`disks-v0-<ver>.xml` in the shipped `<disks version="N">` shape (so a client can
migrate its URL before it migrates its parser), and a committed copy at
`catalog/v0/<ver>/catalog.json`. Then it writes `build/catalog-v0/index-v0.json`
and `catalog/v0/index.json`.

`gen_catalog.py --index` regenerates only the index. Use that when you promote a
version's `status` or move `default` in a `version.json` and nothing was rebuilt.

The `generation` counter is content-derived on purpose. iOS's
`checkCatalogVersionAndInvalidate` compares it against a stored value and calls
`deleteCatalogDisks` when it differs, so it must not move when nothing moved — a
hand-incremented number does — and it must be monotonic, which a content hash is
not. So: hash `[(filename, sha256)]`, and bump the counter in
`versions/<ver>/generation.json` only when that digest changes. The counter is
per RomWBW version, so a user toggling 3.5.1 → 3.6.0 → 3.5.1 does not have their
library deleted twice.

**Stage 6 — `tools/verify_release.sh [ver ...]`.** Runs `tools/verify_catalog.py`
against each built directory and then `--index` against the tree. It re-derives
every claim rather than trusting the generator, so a bug in `gen_catalog.py`
cannot certify its own output.

### Time and space

Measured on an Apple Silicon Mac with both upstream packages already cached:

- Full clean rebuild, `rm -rf build && tools/build_all.sh`: **8.0 s wall**.
- `tools/verify_release.sh` over both versions: **0.4 s**.

The first run on a fresh machine is dominated entirely by two ~200 MB downloads;
how long that takes is your link, not this repo.

Disk:

- `build/`: 202 MB for 3.5.1, 234 MB for 3.6.0 — about 440 MB for both. Not
  committed.
- `$ROMWBW_CACHE` (defaults to `$HOME/esrc`, `tools/common.sh:17`): about 855 MB
  for two releases — 403 MB of kept `Package.zip` files under
  `$ROMWBW_CACHE/.romwbw-dl`, plus 210 MB and 242 MB of extracted build inputs.
  It lives outside the repo deliberately and is shared between versions. Set
  `ROMWBW_CACHE` to move it.

Deleting `$ROMWBW_CACHE/.romwbw-dl` costs a re-download; deleting `build/` costs
8 seconds.

## 3. Reproducibility

A clean rebuild produces **all 48 artifacts byte-identical** — 2 ROMs and 20 disk
images for 3.5.1, 2 ROMs and 24 for 3.6.0. Including the two catalogs, the two
legacy XML files and the index, all 53 generated files match.

Separately, `emu_avw-v0-3.5.1.rom` has

```
sha256  4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258
```

which is byte-identical to the `emu_avw.rom` bundled in all four clients today.
The rebuilt `w8.com` and `r8.com` (1792 bytes each, `9e69cb68…` and `18515399…`)
are byte-identical to the copies inside the currently shipped `hd1k_combo.img`.
This repo is a recipe for the binaries that already ship, not a new set of them.

### Checking the rebuild claim yourself

```sh
cd /path/to/romwbw_disks
tools/build_all.sh
python3 - <<'PY' > /tmp/before.json
import hashlib, glob, json
print(json.dumps({p: hashlib.sha256(open(p,'rb').read()).hexdigest()
                  for p in sorted(glob.glob('build/v0-romwbw-*/*')
                                  + glob.glob('build/catalog-v0/*'))}, indent=1))
PY

rm -rf build
tools/build_all.sh

python3 - <<'PY'
import hashlib, glob, json
before = json.load(open('/tmp/before.json'))
after = {p: hashlib.sha256(open(p,'rb').read()).hexdigest()
         for p in sorted(glob.glob('build/v0-romwbw-*/*')
                         + glob.glob('build/catalog-v0/*'))}
print("before %d  after %d" % (len(before), len(after)))
print("missing:", sorted(set(before) - set(after)))
print("extra:  ", sorted(set(after) - set(before)))
print("DIFFER: ", [k for k in before if after.get(k) != before[k]])
PY
```

All four lists must be empty and both counts must read 53.

### Checking the shipped-ROM claim yourself

From a directory holding all four client checkouts:

```sh
shasum -a 256 \
  romwbw_emu/roms/emu_avw.rom \
  romwbw_emu/web/emu_avw.rom \
  z80cpmw/roms/emu_avw.rom \
  ioscpm/iOSCPM/Resources/emu_avw.rom \
  cpmdroid/app/src/main/assets/emu_avw.rom \
  romwbw_disks/build/v0-romwbw-3.5.1/emu_avw-v0-3.5.1.rom
```

All six lines must read `4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258`.

Note that `docs/ROM_ATTESTATION.md` in ioscpm is an Apple App Store filing that
names `emu_avw.rom` specifically and cites `github.com/avwohl/romwbw_emu` as the
GPLv3 corresponding-source URL. Renaming or relocating that ROM has
legal-document consequences beyond this repo.

## 4. Publishing

### Before you publish anything

The catalogs bake absolute URLs. `tools/gen_catalog.py:36` hardcodes
`REPO = "avwohl/romwbw_disks"`, `:44` derives `INDEX_TAG = "catalog-v0"`, and
every `base_url`, `catalog_url` and `disks_xml_url` is built from them. The
generated catalogs are only correct if published at exactly those tags in exactly
that repository. A fork or a rename requires editing `gen_catalog.py` and
regenerating, not just re-uploading.

Commit and push first. `gh release create` makes the git tag at the commit you
name, so cut it from a pushed commit and put the commit in the release notes —
that is the only link between an asset and the source that produced it.

### The order is: version tags first, index last

`index-v0.json` names each `catalog_url` along with its `catalog_sha256` and
`catalog_size`. If the index goes live before the release it points at, every
client that fetches it gets a 404 on a URL the index swears is there.

### Cutting a per-version release (immutable)

`tools/publish_release.sh` scripts this whole section — verify, create each
version tag, upload by name, index last. On a `v0-romwbw-*` tag that already
exists it never changes a published asset: it compares each asset's size
against what it would upload, leaves the ones already up untouched, uploads
only what is missing, and aborts by name if any size differs. That is what
makes an interrupted 200 MB upload recoverable without making an immutable
tag editable. The commands below are what it runs, and what to do by hand
when you want to watch each step land.

```sh
V=3.5.1
TAG="v0-romwbw-$V"
REPO=avwohl/romwbw_disks

# Draft first.  A public release with half its assets uploaded is a release a
# client can fetch and fail on.
gh release create "$TAG" --repo "$REPO" --draft \
    --target "$(git rev-parse HEAD)" \
    --title "RomWBW $V — interface v0" \
    --notes "Interface v0 assets for RomWBW $V.
Built from $(git rev-parse --short HEAD) with tools/build_all.sh $V.
Sizes and hashes: catalog-v0-$V.json.
Entry point: https://github.com/$REPO/releases/download/catalog-v0/index-v0.json"

gh release upload "$TAG" --repo "$REPO" build/"$TAG"/*

# 24 files for 3.5.1, 28 for 3.6.0.  Check before you publish.
gh release view "$TAG" --repo "$REPO" --json assets \
  --jq '.assets | length, (.[].name)'

gh release edit "$TAG" --repo "$REPO" --draft=false --latest=false
```

`--latest=false` is not decoration. See section 6.

### Cutting the index (mutable)

First time only:

```sh
gh release create catalog-v0 --repo "$REPO" \
    --target "$(git rev-parse HEAD)" \
    --title "Interface v0 catalog index" \
    --notes "The floating entry point for interface v0.
This release carries index-v0.json and nothing else.  Its asset is replaced in
place whenever a RomWBW version is added, promoted or rebuilt.  Every artifact
lives on an immutable v0-romwbw-<version> tag." \
    --latest \
    build/catalog-v0/index-v0.json
```

Every time after that:

```sh
python3 tools/gen_catalog.py --index
gh release upload catalog-v0 --repo "$REPO" \
    build/catalog-v0/index-v0.json --clobber
```

`--clobber` replaces a published asset. This is the **one** place in this
repository where that is correct, and section 5 explains why it is wrong
everywhere else. Re-uploading an asset does not move the git tag, so
`catalog-v0` stays where it was cut.

How long GitHub's CDN serves the previous copy after a `--clobber` is not
something this repo has measured. Do not assume propagation is instant, and do
not build any client behaviour on it being instant.

### Why the split exists

Two independent reasons, and both matter.

**The floating entry point has to be cheap to re-cut.** A client needs one URL
that never changes and always tells the truth about which RomWBW versions exist —
that is the whole reason this repo exists, so that adding RomWBW 3.7.0 does not
require rebuilding four apps. That URL therefore has to be re-published every time
the version set changes. `index-v0.json` is 2942 bytes. If the index shared a tag
with the artifacts, re-cutting it would sit next to 51 MB disk images and invite
someone to re-upload one, which would churn a file that clients have already
downloaded and cached by name.

**GitHub release asset URLs cannot be redirected.** There is no rename, no alias,
no 301. A URL of the form
`https://github.com/avwohl/romwbw_disks/releases/download/v0-romwbw-3.5.1/hd1k_combo-v0-3.5.1.img`
is either that exact byte sequence or a 404, forever. So the tag carrying the
artifacts must be immutable: once a client build has shipped with that URL
compiled or cached into it, that URL is a permanent obligation. The only way to
have a moving pointer at all is to put the moving part somewhere the immutable
part is not.

Client-side, three things make the immutability load-bearing rather than
theoretical. Download directories in all three GUI clients are flat and keyed on
the catalog filename alone: iOS `Documents/Disks/`, Android
`externalFilesDir/Disks`, Windows `downloadDir + "\\" + filename`
(`DiskCatalog.cpp:191,340`) with a ledger beside them at
`downloadDir + "\\disk_ledger.json"` (`DiskCatalog.cpp:733`). Saved-state
identity is filename-only too — iOS `EmulatorProfile.swift:46-49`, CPMDroid's
`disk_slot_0..3` prefs (`SettingsRepository.kt:37,61-69`), Z80CPMW's
`config::DiskConfig{path, isManifest}`. And iOS's
`checkCatalogVersionAndInvalidate` deletes downloaded catalog disks when the
generation changes. A filename that changes meaning breaks saved state in all
three; a generation that moves for no reason deletes a user's library.

## 5. Never

**Never delete or re-point an existing `v0-romwbw-*` tag once a client has
shipped against it.** Not with `gh release delete`, not with `git push --delete`,
not by moving the tag to a new commit. There is no redirect. The URL either
resolves to the bytes it always resolved to, or a shipped client fails.

**Never change a published asset in place.** The only asset in this repository
that is ever replaced is `index-v0.json` on `catalog-v0`, and that is safe only
because it is 2942 bytes, is fetched fresh, and has nothing cached downstream
of it.

`tools/publish_release.sh` enforces this rather than relying on discipline. It
passes `--clobber` only for `index-v0.json`; per-version assets are uploaded by
name, without it. On a tag that already exists it compares each asset's size
against what it would upload and then either

- leaves it alone, if it is already up at the right size, or
- aborts, if the sizes differ — that is someone changing an immutable
  artifact, and it is refused by name.

Anything missing is uploaded. That is deliberate: `gh release create` and
`gh release upload` are two commands, so an upload that dies partway through
200 MB leaves a real release carrying only some of its assets. Refusing every
existing tag outright made that state unrecoverable; refusing only *changes*
lets an interrupted publish be finished.

**A corrected artifact gets a new RomWBW version entry or a new interface
version — never a silent replacement.** If upstream ships 3.5.2, that is a new
`versions/3.5.2/` and a new `v0-romwbw-3.5.2` tag. If the contract itself has to
change, that is `v1`: new release tags, a new index URL, and every v0 tag left
untouched, as [INTERFACE_V0.md](INTERFACE_V0.md) describes.

**A new RomWBW version has a `romwbw_emu` side, and it comes before the tag.**
Since `romwbw_emu` v1.39 the core carries no compile-time version pin, but it
does carry a list: `emu_validate_rom_hcb` refuses by name any release not in
`ROMWBW_SUPPORTED_RELEASES` (`romwbw_emu/src/romwbw_pin.h`). A newly built
3.7.0 ROM will not load anywhere until an `X()` line is added there, and that
line is a claim that somebody booted the release — so boot it first
(`tools/boot_test.sh 3.7.0`), then add the line. Publishing a version no core
will load is how you ship 234 MB nobody can use.

### Correcting a version that is already published

There is no room in the naming scheme for a respin: assets are
`<id>-v0-<ver>.<ext>` on `v0-romwbw-<ver>`, and `tools/common.sh:59` and `:62`
derive both the tag and every filename from those two numbers alone. This
document used to say that if a respin were ever needed it would be a design
decision about the naming scheme, to be made before anything was uploaded. It
was needed on 2026-09-06, and this is that decision.

**Overwrite the assets in place, and bump `generation`. Do not invent a new
name.** The `generation` counter already *is* the mechanism for content changing
under a fixed filename — that is the whole reason it is content-derived rather
than hand-set (section 3). Adding `-r2` to a tag or a filename would instead
change what a filename *means*, and section 4 spells out what that costs: all
three clients key saved state on the filename, so every user's downloaded
library would be stranded under names nothing fetches any more.

**What made it safe this once, and why it will not be next time.** Immutability
protects installed clients, and on 2026-09-06 no shipped client could see these
URLs at all. Download counts on the v0 assets were 2 to 9, which is this
repository's own verification traffic. The rule was protecting nobody, so the
respin cost nothing.

**Do NOT establish that with `git tag --contains`.** That was the first check
tried here and it is worthless on these repositories, because they release
without tagging: on 2026-09-06 the App Store was serving ioscpm 1.5.1, released
the previous day, and there is no `v1.5.1` tag in the repository at all — the
newest tag is `v1.4.12`. An empty `git tag --contains` says nothing about what
users have.

**The check that does answer it** is what the SHIPPED SOURCE fetches. It takes
three steps and every one of them has a trap in it, so the commands are given
with the answers they produced on 2026-09-06:

```sh
cd ../ioscpm
sh tools/check-store-version.sh              # 1. read ONLY "serves" and "released"

grep -nE '^## Version|NOT COMPILED' CHANGELOG.md  # 2. newest build with NO marker
git log --reverse --format='%h %ad %s' --date=short \
    -S'CURRENT_PROJECT_VERSION = 61;' -- iOSCPM.xcodeproj/project.pbxproj | head -1

git grep -n 'releaseTag\|index-v0' af0b9b2 -- iOSCPM   # 3. can that build see us?
```

**Step 1 yields a version, never a build,** and until 2026-09-06 the script did
not admit that. A marketing version does not name one build — every ioscpm
CHANGELOG heading from build 43 to build 65 reads `Version 1.5.1` — but the
lookup returns only the version, and the script took the FIRST heading matching
it. That is the newest build written, which is the opposite of the question. It
printed `which is build 65` and then `The tree and the Store agree on what users
have`, with four never-compiled builds sitting between tree and Store.

It now answers with a range and narrows it by what could physically have been
submitted: these clients are written on a Linux machine with no Xcode, each such
CHANGELOG entry opens with a literal `**NOT COMPILED` line, and a build that
never reached a compiler cannot be the one Apple is serving. Today it prints

    which is         at most build 61  (1.5.1 heads builds 43-65;
                     62, 63, 64, 65 NOT COMPILED, so none of those can be it)

which is the honest answer. If you are reading an older transcript, or any tree
whose copy of that script still prints a bare `which is build N` for a version
that heads more than one build, that number is a guess — re-derive it with
step 2.

**Step 2 turns that build number into a commit,** and confirms it by hand.
Builds 62-65 all carry a `NOT COMPILED` marker and were all committed on
2026-09-05, after that day's release went live, which leaves build 61 as the
newest build that could have been submitted. Then map build to commit — and note
that `-S` matches the commit that ADDS a string and the one that REMOVES it, so
`-S'CURRENT_PROJECT_VERSION = 61;'` returns both `af0b9b2` ("Build 61") and
`5ae96ac` ("Build 62"); `--reverse | head -1` takes the one that set it. Do not
assume every build number exists, either: `ffbe12c` went straight from 62 to 64,
so `Build 63` is a CHANGELOG heading with no commit behind it.

**Step 3 must grep the SYMBOL, not the URL.** The catalog URL is interpolated —
`releaseTag = "v1.4.12"` on one line and `"...download/\(releaseTag)/disks.xml"`
on the next (`EmulatorViewModel.swift:162-163` as of `af0b9b2`) — so
`git grep 'v1\.4\.12/disks\.xml' af0b9b2 -- iOSCPM` matches NOTHING — an empty
result that reads as the exact opposite of the truth. Keep the `-- iOSCPM`: drop
it and the same grep hits `docs/DISK_CATALOG_PINNING.md` and
`docs/DISK_DISTRIBUTION.md`, which are prose about the pin and not the pin. And
keep the `releaseTag` half of the pattern, because a mistyped PATHSPEC fails
silently — `git grep -l 'index-v0' af0b9b2 -- iOSCPMX` exits 1 with no output,
indistinguishable from a real "this build cannot see us", whereas a mistyped rev
is loud. The `releaseTag` hits are what prove the pathspec resolved.

Those three steps gave: the Store serves 1.5.1, released 2026-09-05; that is
build 61, which is `af0b9b2`; and `af0b9b2` fetches
`avwohl/ioscpm/releases/download/v1.4.12/disks.xml` with no occurrence of
`index-v0` anywhere in it — that first entered the tree at `ffbe12c`, builds
63-64, which has never been compiled, let alone shipped. So the shipped client
had never heard of this repository, which is the fact the respin needed — and
note it is `v1.4.12` that the live build fetches, not `v1.4.5`. cpmdroid and
z80cpmw are the same shape: both shipped builds predate their migration commits.

**That window is now closed.** The moment a client ships against these URLs,
overwriting a published asset means a client that already verified a SHA-256
gets different bytes at the same URL, and the only signal it has is a
`generation` it may not re-read until its next index fetch. After that, a
correction to a published version is a NEW RomWBW version entry or nothing.
Establish what shipped with the three steps above before assuming otherwise —
not with `git tag --contains`, which is what got this wrong the first time.

**`tools/publish_release.sh` cannot do a respin, and will not say so.** It skips
any asset whose size matches what it would upload (section 4). A rebuilt ROM is
512 KB before and after, so it silently leaves the old bytes in place — while
still uploading the new `catalog-v0-<ver>.json` that hashes the new ones. The
result is a published catalog whose every ROM entry fails verification in every
client. Respin by hand with `gh release upload --clobber`, naming each changed
asset, and re-run section 7 against a clean directory afterwards.

**The old `avwohl/ioscpm` tags `v1.4.5` and `v1.4.12` must stay live
indefinitely,** and as of 2026-09-06 neither is a legacy concern. Every shipped
client fetches from one of them:

	ioscpm	App Store 1.5.1	build 61, `af0b9b2`	`v1.4.12`
	cpmdroid	Play 1.25	versionCode 27	`v1.4.5`
	z80cpmw	Store 1.0.23		`v1.4.5`

Two installed clients are on `v1.4.5`, not one. cpmdroid is the one to get right
by hand, because versionCode 27 was minted BEFORE the repin that moved it to
`v1.4.12` — its own commit `90fe0c2` settles it: "27 was minted before the repin,
so Play's 1.25 fetches `v1.4.5`." Do not reason from the newest commit that
carries a version string; reason from the one that minted the number the store
serves. Deleting either tag breaks installed software today.

**The pins are gone from all three trees as ASSIGNMENTS, but grep still finds
them as prose.** `releaseTag` in ioscpm's `EmulatorViewModel.swift`,
`RELEASE_TAG` in cpmdroid's `DiskCatalogRepository.kt` and in z80cpmw's
`DiskCatalog.cpp` were deleted by the v0 migration, and each was replaced by a
comment above the new index constant that quotes what it replaced
(`EmulatorViewModel.swift:386`, `DiskCatalogRepository.kt:94`,
`DiskCatalog.cpp:54`). So `git grep v1.4.12` at HEAD is not empty — it is 14
files in ioscpm, 4 in cpmdroid, 12 in z80cpmw. What it will not find is a live
assignment, and that is the actual trap: `tools/check-shipped-disks.sh`'s `pin_of`
strips comment lines and so returns empty for all three ports, which reads as
"nothing is pinned" rather than "the pin moved".

To learn what pin a SHIPPED build carries, `HEAD` is the wrong place — but so is
`git show <tag>:<file>`, because none of these shipped builds is tagged
(cpmdroid's newest tag is `v1.24` with no `v1.25`; z80cpmw's is `v1.0.22-beta`
while the Store serves 1.0.23). Read it out of the commit that minted the store's
version number, or out of the artifact — in a z80cpmw package it is UTF-16LE,
being a `std::wstring`. To learn whether the tags still MATTER, `HEAD` is exactly
right, and the answer is bigger than installed binaries: all three current trees
still fetch in-app help from `avwohl/ioscpm/releases/latest/download/`
(`HelpView.swift:187-188`, `HelpWindow.cpp:24,26`, `HelpActivity.kt:334`), which
resolves to `v1.4.12` today. Deleting it breaks help in builds made from HEAD,
never mind the ones users have.

Those tags are not this repository's, but publishing here does not retire them,
and nothing about this migration makes them safe to remove. They stay until no
installed build points at them, which in practice means indefinitely.

**`tools/check-shipped-disks.sh` is one script again, and was three for three
days.** It is in five repos — cpmdroid, cpmemu, ioscpm, romwbw_emu and z80cpmw;
romwbw_disks has never had it — and all five are md5
`9a2295b9f082430f870a5bb87a2c55b2` as of 2026-09-06. (The file was
`tools/check-disk-pins.sh` until that day; renaming a script that names itself
in its own header changes every copy's hash.)

They were identical when they were added on 2026-09-03, and diverged because
the v0 migration updated the checker in the two clients it touched first
(`ffbe12c` in ioscpm, `41829cb`/`bb0ac74` in cpmdroid) and did not touch
z80cpmw's or romwbw_emu's at all — so z80cpmw migrated its client on `17c72fa`
and left its checker on the pre-migration script. cpmdroid's copy went furthest,
growing a whole `index-v0` port kind that checks a migrated port properly instead
of reporting `NO PIN FOUND` at it, and its own header said so: "THIS COPY HAS
DIVERGED and the other four need the same edit". Reconverged on 2026-09-06 by
taking that copy as canonical, moving ioscpm and z80cpmw into the `index-v0` row
now that both have migrated, and copying the result to all five. Do not assume a
fix to one copy reaches the others; nothing carries it but a person.

What all four still share is that each
hardcodes `CATALOG_REPO="avwohl/ioscpm"`, treats `hd1k_combo.img` as the single
canary, and scans built artifacts for the regex `v1\.[0-9]+\.[0-9]+`. That regex
matches neither `v0` nor `3.5.1`. It goes blind the moment a client migrates.

## 6. Prerelease and "Latest"

This is the part most likely to bite, because the family already has one live
instance of it going wrong.

**What is wrong today, upstream of here.** On `avwohl/ioscpm`, measured
2026-09-04: release `v1.4.12` is `prerelease=false` and **is** GitHub's "Latest".
Four in-tree documents treat `--prerelease` as load-bearing and assume it is set.
It is not. `releases/latest` on that repo is genuinely load-bearing: the App Store
fleet is 1.4.9 (builds 36/37), which predates both the catalog narrowing and the
pin, so it still floats on `releases/latest/download/`. Whatever release is
marked Latest on ioscpm is serving `disks.xml` to installed phones. The only thing
preventing an incident right now is that `<disks version="13">` is identical on
`v1.4.5`, `v1.4.11` and `v1.4.12`, so the iOS generation-change wipe cannot fire.
That is luck, not design.

**The rule for this repository.**

- `catalog-v0` is marked Latest. `--latest` on create; leave it there.
- Every `v0-romwbw-*` release is cut with `--latest=false`. Always, explicitly.
- Do **not** use GitHub's `prerelease` flag to mean "preview".

The third one needs saying. "Preview" is data, not release metadata: it is
`status` in `versions/<ver>/version.json`, which flows into `catalog.status` and
into each index entry. RomWBW 3.6.0 was `"status": "preview"` while no emulator
could load it — `emu_validate_rom_hcb` compared the loaded ROM's HCB bytes
against a compile-time pin and refused. Since `romwbw_emu` v1.39 the core reads
the version out of the ROM and boots either release, and 3.6.0 was promoted to
`"stable"` on 2026-09-05, and `"default"` moved to it the same day. Promoting a
release and recommending it are different acts done for different reasons, and
both were taken here deliberately rather than together by habit.

Note what promotion did NOT wait for, because it is the interesting part: no
released client carries that core, so no shipped build can boot a 3.6.0 ROM.
That is safe because a client filters the index by `hbios.ver_byte` /
`hbios.upd_byte` against what its own core can run, so 3.6.0 never survives the
filter on a pre-v1.39 build. `status` is advice for a client that CAN boot a
release; the version bytes are what stop one that cannot. A client reads that
status out of the index. It does not, and must not,
infer anything from a GitHub badge. Encoding the same fact in two places is how ioscpm ended up with four
documents describing a flag that was never set.

The script does set the flag — `[ "$status" = "stable" ] || prerelease="--prerelease"`
— so `v0-romwbw-3.6.0` is published as a prerelease. That is a second encoding
of `status`, and the objection above is the right one: two encodings of one
fact drift, which is exactly how ioscpm ended up with four documents describing
a flag that was not set.

It is kept, because the flag is the only thing that tells a human browsing the
releases page that 3.6.0 is not ready, and because dropping it would leave the
GitHub UI actively misleading. What is not kept is the trust: after every
publish, `tools/publish_release.sh` reads the flag back off each release and
fails if it disagrees with that version's `status` in the manifest. So the two
encodings cannot drift silently — but "cannot drift" means "the next publish
catches it", not "it never happens". Three things put them out of step between
publishes: a manual edit in the GitHub UI, promoting a version from `preview`
to `stable` in `version.json` without re-publishing, and section 4's by-hand
recipe, which creates the release itself and so can set the flag differently
from what the manifest says. Each is caught the next time
`tools/publish_release.sh` runs, and not before.

The rule that stands unchanged is the one for clients: **the index's `status`
is authoritative, the GitHub flag is a label.** A client must never infer
anything from a release badge.

**Why the index tag is the only one whose Latest status matters.** No client URL
in this repository resolves `releases/latest`. Every one names a tag explicitly —
`catalog-v0` for the index, `v0-romwbw-<ver>` for everything else. So Latest is
inert here *today*.

It is still worth pinning, for two reasons. GitHub assigns Latest automatically to
the newest non-prerelease, non-draft release if you do not say otherwise, so
cutting `v0-romwbw-3.7.0` without `--latest=false` would silently displace
`catalog-v0` and make a 234 MB image dump the repository's front door. And the
family already has a habit of floating on `releases/latest` — the help-text fetches
do it deliberately (`ioscpm/.../HelpView.swift:187-188`,
`z80cpmw/.../HelpWindow.cpp:17,19`, `cpmdroid/.../HelpActivity.kt:208` with a
fallback at `:334`), iOS and Windows at ioscpm's `releases/latest/download/` and
CPMDroid at its own repo's, with an ioscpm URL only as the `base_url` default at
`:334`. If a future client ever reaches for `releases/latest` on this repo, the
only thing that is safe to find there is a 2942-byte index. Keeping `catalog-v0`
marked Latest makes the wrong guess degrade into the right answer.

Check what is actually live rather than what you meant to do. `gh release view`
has no `isLatest` JSON field — gh 2.93.0 answers `Unknown JSON field: "isLatest"`
— so read it from the list output's Latest column or from the API:

```sh
gh release list --repo avwohl/romwbw_disks          # the Latest column
gh release view catalog-v0 --repo avwohl/romwbw_disks \
  --json tagName,isDraft,isPrerelease,publishedAt
gh api repos/avwohl/romwbw_disks/releases/latest --jq .tag_name
```

## 7. Verifying a published release

`tools/verify_catalog.py` takes a catalog and a directory. It does not care where
the directory came from — a build tree or a directory of freshly downloaded
assets works identically, which is the point. It re-reads every artifact and
re-derives every claim, independently of `gen_catalog.py`.

For each ROM it checks presence, size, `sha256`, that the HCB at `0x103` reads
`57 a8` plus the packed version bytes for that release, and that no foreign CBIOS
banner appears anywhere in the file (which is what catches a dev snapshot used as
banks 1–15). For each disk it checks presence, size, `sha256`, that every CBIOS
banner in the slice matches the release, that the catalog's `cbios` and
`bootable` claims match what the boot track and the slice actually say, and — for
any image claiming `host_transfer` — that `w8.com` and `r8.com` are in the CP/M
directory and that the `06 e9 cf` interlock is present.

`bootable` is measured from the first 16384 bytes of the slice, not from a string.
An hd1k image that was never made bootable has its boot track left at the CP/M
fill byte `0xE5`, uniformly non-zero, so "any byte set" would call every data disk
bootable. CP/M 3 and ZPM3 slices load `BIOS3.SPR` and carry no `CBIOS v` banner at
all, so a banner test alone would wrongly report them as data-only.

The layout the index verifier expects — `<dir>/<release_tag>/<catalog file>` —
is the same layout `build/` has, so the same `--index` check works against
downloaded assets:

```sh
#!/bin/sh
# Verify a published interface-v0 release from outside.  Downloads ~440 MB.
set -eu

REPO=avwohl/romwbw_disks
IDX="https://github.com/$REPO/releases/download/catalog-v0/index-v0.json"
WORK="${1:-./published}"
TOOLS="$(cd "$(dirname "$0")" && pwd)"   # or the path to romwbw_disks/tools

mkdir -p "$WORK"
curl -fsSL -o "$WORK/index-v0.json" "$IDX"

python3 -c '
import json, sys
for e in json.load(open(sys.argv[1]))["romwbw_versions"]:
    print(e["release_tag"], e["catalog_url"], e["disks_xml_url"])
' "$WORK/index-v0.json" | while read -r tag caturl xmlurl; do
    cat_file="$WORK/$tag/$(basename "$caturl")"
    mkdir -p "$WORK/$tag"
    curl -fsSL -o "$cat_file" "$caturl"

    # The legacy XML is advertised by the index, not listed in the catalog's
    # roms[]/disks[], so the loop below will not fetch it - and the --index pass
    # checks for it.  Fetch it here or that pass fails on a correct release.
    curl -fsSL -o "$WORK/$tag/$(basename "$xmlurl")" "$xmlurl"

    python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
for a in c["roms"] + c["disks"]:
    print(c["base_url"] + a["filename"], a["filename"])
' "$cat_file" | while read -r url fn; do
        [ -f "$WORK/$tag/$fn" ] || curl -fsSL -o "$WORK/$tag/$fn" "$url"
    done

    echo "=== $tag ==="
    python3 "$TOOLS/verify_catalog.py" "$cat_file" "$WORK/$tag"
done

echo "=== index ==="
python3 "$TOOLS/verify_catalog.py" --index "$WORK/index-v0.json" "$WORK"
```

Every result line must read `ok` — the `catalog …`, `index …` and `=== tag ===`
lines are headers, not results. The script exits non-zero if anything failed.

The `--index` pass additionally checks that exactly one RomWBW version is marked
`default`, and that each catalog's size, `sha256`, `generation` and
`romwbw_version` agree with what the index says about it. That is what catches
the specific mistake of publishing a rebuilt catalog without re-cutting the index.

## 8. Checklist

Build:

- [ ] `um80 --version` and `ul80 --version` agree with each other; note the version.
- [ ] `cpmcp`, `cpmrm`, `cpmls` on `PATH`.
- [ ] `rm -rf build && tools/build_all.sh` exits 0 and ends with
      `PASS: every artifact matches its catalog entry`.
- [ ] `tools/boot_test.sh` exits 0 **and** its last summary line names every
      version you are about to publish — `One emulator binary booted v3.5.1
      v3.6.0 - 2 published releases.` It needs the populated `build/` from the
      step above, and `build_all.sh` does not run it for you. A `SKIP` line
      means no emulator was found, which is not a pass.
- [ ] 53 generated files, all byte-identical to the previous build (section 3).
- [ ] `emu_avw-v0-3.5.1.rom` is still `4b11402a…` — if it is not, stop and find out why.
- [ ] `git status` is clean apart from `build/`; `versions/*/generation.json` and
      `catalog/v0/**` changes are intentional and reviewed.
- [ ] `build/` is not committed.

Publish, in this order:

- [ ] Commit and push. Note the commit hash.
- [ ] For each version: `gh release create <tag> --draft --target <commit>`.
- [ ] `gh release upload <tag> build/<tag>/*`.
- [ ] Asset count is 24 for 3.5.1, 28 for 3.6.0 (2 ROMs, 20 or 24 images,
      `catalog-v0-<ver>.json`, `disks-v0-<ver>.xml`).
- [ ] `gh release edit <tag> --draft=false --latest=false`.
- [ ] Only after every version tag is public: `gen_catalog.py --index`, then
      upload `index-v0.json` to `catalog-v0` with `--clobber`.
- [ ] `gh api repos/avwohl/romwbw_disks/releases/latest --jq .tag_name` reports
      `catalog-v0`, and `gh release list` shows the Latest badge on no
      `v0-romwbw-*` release.

Verify:

- [ ] Run the section 7 script against a clean directory. Every result line `ok`.
- [ ] Fetch the index URL once more by hand and confirm it lists the version you
      just published.

Do not:

- [ ] delete or re-point any `v0-romwbw-*` tag;
- [ ] `--clobber` anything except `index-v0.json`;
- [ ] mark a per-version release Latest;
- [ ] touch `avwohl/ioscpm` tags `v1.4.5` or `v1.4.12`.

## Known open work

**3.6.0 has been run, and the `proto.asm` task was never possible as written.**
There is no `Source/HBIOS/proto.asm` in any RomWBW release; both places that
demanded one — `romwbw_emu`'s `src/romwbw_pin.h` and `DOWNSTREAM.md` — have
been rewritten, and `DOWNSTREAM.md` now says so outright. What was done instead
on 2026-09-05: under `romwbw_emu` v1.39, 3.6.0 boots CP/M 2.2, banked CP/M 3,
ZPM3, Z3PLUS, ZSDOS and NZCOM from the images published here, `R8`/`W8`
round-trip a file byte-identically, and the boot loader prints
`NV Switches Found`.

Be precise about what is machine-checked. `tools/boot_test.sh` asserts the
CP/M 2.2 half, for every release the emulator says it can run: the combo image
boots, the `CBIOS v<ver> [WBW]` banner appears, the CP/M prompt is reached, the
emulator reports the release it read from the ROM, a disk from another release
warns, and `R8`/`W8` round-trip a file byte-identically. The other five
operating systems and the NVRAM check were run by hand on 2026-09-05 and are
not re-run by any script.

Still not done: a function-by-function read of 3.6.0's `hbios.asm` against the
emulator's dispatcher. See [ROMWBW_VERSIONS.md](ROMWBW_VERSIONS.md).

3.6.0 was promoted to `"status": "stable"` on 2026-09-05, on the emulator
evidence rather than on a shipped client: `romwbw_emu` v1.39 boots it and
`tools/boot_test.sh` asserts the boot, the banner, the absence of a mismatch
warning and an R8/W8 round trip on every run. No released client carries that
core, and that is deliberately not a blocker — a shipped client filters 3.6.0
out by `hbios.ver_byte`, so the entry is invisible to the builds that could not
boot it. `"default"` moved to 3.6.0 on the same day.

**What `default` on 3.6.0 exposes.** No client downloads a ROM yet - each
bundles a 3.5.1 `emu_avw.rom` - so a client that shipped today would preselect
3.6.0 disks and boot them against a 3.5.1 ROM, which the guest answers with
`*** WARNING: HBIOS/CBIOS Version Mismatch ***`. ioscpm says so before it
happens (`romReleaseMismatchNotice`), so it is warned rather than silent, but it
is a poor first run. Nothing is affected today because no released client reads
this index at all.

The ROM is the last version-coupled thing left in a client, and fetching it from
the catalog is what finishes the job this repository was created to do: a new
RomWBW version should need a release HERE and nowhere else. `roms[]` has been in
every catalog from the start for exactly that - `emu_avw` with `default: true`,
a `sha256` and a size, under the same `base_url` as the disks. Re-bundling a ROM
per release is the wrong answer; it puts a client release back on the critical
path for every RomWBW bump. Keep a bundled ROM as the first-launch fallback and
download the rest.

**How a promotion is done, since it is not a rebuild.** Edit `status` in
`versions/<ver>/version.json`, run `tools/gen_catalog.py --index`, and publish
only `index-v0.json` to the floating `catalog-v0` tag. Do not re-cut the
version's own assets: `catalog-v0-<ver>.json` is on the immutable
`v0-romwbw-<ver>` tag and keeps the status it was published with, which is why
`tools/check_committed.py` allows a catalog saying `preview` under a manifest
saying `stable` and nothing else. The index is what a client reads `status`
from, so the index is what has to move.

`tools/publish_release.sh` is undocumented — it appears neither in this document's
original text nor in `tools/README.md`'s script table — and it sets `--prerelease`
in a way section 6 rules out. Either wire it into this document properly or
delete it before someone runs it expecting section 4's behaviour.
