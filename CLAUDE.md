# romwbw_disks

**This repository is the publisher.** The ROM images and CP/M disk images that
every client downloads are built here and published as GitHub release assets
behind a two-level catalog. Nothing else in the family ships an artifact.

    index-v0.json                    the entry point, one small document
      -> catalog-v0-<release>.json   one per RomWBW release
        -> the ROMs and disk images  hash and size named by the catalog

The point of it: adding a RomWBW release, a ROM, a disk image or a help topic
is a release *here*, and it reaches everyone who already installed a client.
No client rebuild, no app-store submission.

## The entry point names no tag, and `--latest` is what holds it up

    https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json

`releases/latest/download/` resolves to whichever release carries the Latest
flag, so *where the index lives* belongs to this repository and can move with no
client release. That freedom is bought with one flag: `gh release create` claims
Latest **by default**, so cutting any release without `--latest=false` repoints
every installed client at a release with no `index-v0.json` on it.

That has already happened once, on 2026-09-10, and the URL answered 404 until
the flag was put back. `tools/check_latest.py` exists to fail this repository if
the URL a client really uses ever stops being the index. `tools/publish_release.sh`
passes `--latest` when it cuts `catalog-v0` and `--latest=false` elsewhere;
do not add a release-creating path that omits either.

It was `releases/download/catalog-v0/index-v0.json` until 29635dd. Clients built
before that still ask for the tag by name, so **`catalog-v0` has to stay alive
for as long as any of them are in use** - a GitHub release asset URL cannot be
redirected.

## cpm_disk.py is NOT here

It is cpmemu's, at `cpmemu/util/cpm_disk.py`, and that is the only copy in the
family. This repository vendored one at `tools/cpm_disk.py` and its README
called that copy "the canonical one" while nothing here ever called it; it was
deleted in ff6adec. Do not take another. If a pipeline here ever needs it, reach
into a sibling checkout the way `tools/check_source_drift.sh` already reaches
for romwbw_emu.

## cpmtools IS used here, and that is deliberate

`tools/build_disks.sh` injects `w8.com` and `r8.com` into the stock images with
`cpmcp`/`cpmrm`/`cpmls`, and `tools/diskdefs` carries the `wbw_hd1k_0..5` combo
slice definitions no distribution ships. That is the one place in the family
cpmtools is correct to use - every *client* reads images with `cpm_disk.py`
instead, and romwbw_emu deleted its cpmtools recipes and its `disks/diskdefs`
for that reason.

Two hazards, both live, both the reason `build_disks.sh` checks image sizes
against the shape its diskdef implies **before** writing anything:

- **The wrong diskdef does not fail.** cpmtools reads a garbage directory and
  `cpmcp` writes at the wrong offset while reporting success.
- **cpmtools 2.23 cannot be configured without libdsk**, whose backend cannot
  address past 8 MB from the start of a file. So `wbw_hd1k_1` and up are
  unreachable on any packaged build, and every cpmtools call here runs with
  `tools/` as its working directory so `./diskdefs` is the file picked up.

## Never publish a snapshot

`tools/fetch_romwbw.sh` refuses an upstream tag that is not a plain `vX.Y.Z` and
refuses one GitHub marks as a prerelease. Upstream tags development snapshots
alongside releases, and a snapshot's HCB carries the same two version bytes as
the release it precedes - `v3.7.0-dev.13` reads `37 00`, exactly as a released
3.7.0 would - so nothing downstream could tell them apart.

## Hashes are computed, never transcribed

`tools/gen_catalog.py` writes every catalog and the index from the built
artifacts. `tools/verify_catalog.py` re-derives every claim independently, and
works against downloaded assets too. Do not hand-edit a catalog or an index: a
hand-written hash is a hash nothing measured.

`generation` is one counter per RomWBW version, advanced when any artifact of
that version changes. It is **not** per asset, and clients must not treat it as
one - romwbw_emu's client got that wrong and reported the second artifact of a
multi-artifact re-cut as local damage.

## The Z80 sources are shared with romwbw_emu

`src/r8.asm`, `src/w8.asm` and `src/emu_rom.asm` must stay byte-identical to
romwbw_emu's; `src/emu_hbios.asm` differs only by its generated `romwbw_ver.inc`
parameterisation, which is proved by both trees building the same `emu_avw.rom`.
`tools/check_source_drift.sh` is the check, and it skips when romwbw_emu is not
beside this repo - so a green run on a machine without it has not checked.

They are assembled with `um80` and `ul80` (`pip install um80`) and with nothing
else. Do not install pasmo or z80asm, and do not add a fallback to one: these
are MACRO-80 sources with `.z80`, a `.rel` intermediate and a separate link
step, which is not what those tools read. `src/README.md` has the commands and
the reason neither `.COM` source carries an `ORG`.

`tools/cpm_disk.py` was NOT covered by that script, which is part of why its
copy went unnoticed. If you add a shared file, add it to the drift check in the
same commit, or do not add it.

## Help topics live here

`help/` holds the seven help documents, published on the `help-v0` tag and named
by the index's `help` block with a size and a sha256 each. All four clients read
them from the catalog. Two clients also bundle a copy as an offline floor -
ioscpm's `release_assets/` (which z80cpmw's `.rc` also compiles from) and
cpmdroid's `app/src/main/assets/help/`. Rewriting a topic here leaves those
stale until they are refreshed; ioscpm's `tools/check-help-assets.py` is what
notices.

## Before claiming what is shipped

Every "shipped", "wired in" or "under construction" sentence in this repository
describes the tree, and the tree does not know what a user can install. That is
the same failure `tools/check-store-version.sh` exists for in the clients. This
README said "Nothing here is wired into a shipping client yet" for some time
after all four clients had migrated. Measure before writing such a sentence, and
prefer not writing one.
