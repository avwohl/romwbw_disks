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
the flag was put back. `tools/check_latest.py` fails this repository if the URL a
client really uses ever stops being the index, and since 2026-09-18
`tools/publish_release.sh` runs it as its last step and dies on a failure - it is
still in no CI workflow, deliberately, because what a release channel serves is
not what CI is for. Run it by hand after any release you cut without that script.
`publish_release.sh` passes `--latest` when it cuts `catalog-v0` and
`--latest=false` elsewhere; do not add a release-creating path that omits either.

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

## Do not use cpmtools

**No pipeline here may call `cpmcp`, `cpmrm`, `cpmls` or any other cpmtools
program, and none may be installed to make one work.** This reverses what this
file said until 2026-09-18, which was that cpmtools was correct here and that
this was the one place in the family it belonged.

The reasons it was wrong are already written down in the paragraph that used to
defend it:

- **The wrong diskdef does not fail.** cpmtools reads a garbage directory and
  `cpmcp` writes at the wrong offset while reporting success. `build_disks.sh`
  carries a size check ahead of every write purely to contain that.
- **cpmtools 2.23 cannot be configured without libdsk**, whose backend cannot
  address past 8 MB from the start of a file, so `wbw_hd1k_1` and up are
  unreachable on any packaged build. The tool cannot reach most of the combo
  image it is being asked to write.
- It needs `tools/diskdefs`, a definitions file no distribution ships, and
  every call has to run with `tools/` as its working directory for that file to
  be picked up. Three things to get right before a byte is written.

The reader that replaces it is **`cpmemu/util/cpm_disk.py`**, which is the only
copy in the family and is what every *client* already uses. Reach it out of a
sibling checkout the way `tools/check_source_drift.sh` already reaches for
romwbw_emu. Do NOT vendor a copy here - see the section above, which is about
exactly that mistake.

**The tree obeys this.** `tools/build_disks.sh` was converted on 2026-09-18 and
`tools/diskdefs` is deleted; nothing here calls cpmtools and nothing needs it
installed. Verified by rebuilding every artifact for all three carried versions
on a machine with no cpmtools at all - **all 48 artifacts of 3.5.1 and 3.6.0
come back byte-identical to the assets those tags already serve.**

That byte-identity was not free, and it is the thing to preserve. `cpm_disk.py`
padded a file's last block with `0x1A` where `cpmcp` used `0x00`, which changed
`hd1k_combo` by 4608 bytes - functionally nothing, since the directory entry's
record count is what bounds a file, but enough to make a rebuild differ from its
own publication and to force a re-cut of two immutable tags to adopt the new
tool. `cpmemu/util/cpm_disk.py` pads `0x00` for that reason, and its comment
says so. Do not change it back.

## Snapshots are carried, deliberately and never as the default

This section said **"Never publish a snapshot"** until 2026-09-18. The owner
decided otherwise, and `v3.7.0-dev.14` is carried. The reasoning that produced
the old rule was not wrong, so none of it is deleted - it is the reason for
every guard below.

**The hazard, measured rather than argued.** A snapshot's HCB carries the same
two version bytes as the release it precedes. `v3.7.0-dev.14`'s stock ROM reads
`57 a8 37 00` at 0x103 - byte for byte what a released 3.7.0 will read. So
nothing computed from those bytes can tell them apart, including
`emu_validate_rom_hcb`, which is how every client decides a ROM is loadable.
RomWBW's CBIOS compares major.minor only, so the mismatch warning will not fire
between a snapshot and its release either.

**What separates them is the CBIOS banner, and only that.** It is a string and
it carries the full tag. The asymmetry is worth memorising:

    ROM  (two HCB bytes)  -> emulator prints "RomWBW v3.7.0"
    disk (CBIOS banner)   -> "CBIOS v3.7.0-dev.14 [WBW]"

`tools/boot_test.sh` asserts BOTH halves, including that the ROM does *not*
report the suffix - so if upstream ever changes the HCB, this repository finds
out rather than assuming.

**The four things that make carrying one safe:**

1. **The version directory is named for the full upstream tag** -
   `versions/3.7.0-dev.14/`, not `3.7.0`. That name flows into every asset
   name, the release tag, and `$VER` in `build_disks.sh`'s exact-match banner
   assertion, which is why that assertion needed no change.
2. **`"prerelease": true` in `versions/<ver>/version.json`**, propagated by
   `gen_catalog.py` to the index entry and the catalog. A boolean, because the
   `status` beside it is free text that no client can safely branch on.
3. **It is never the default.** `check_committed.py` and `verify_catalog.py`
   each refuse `prerelease` and `default` on the same entry, independently.
4. **`fetch_romwbw.sh` reads the manifest, not an environment variable.** A tag
   that is not a plain `vX.Y.Z` is refused unless that version has declared
   itself, and a version that declares itself while GitHub calls it a full
   release is refused too. `ALLOW_PRERELEASE=1` remains only for a local build
   of something this repo does not carry.

**Clients must hide it behind an opt-in, and none does yet.** Measured
2026-09-18: all four read this index and would list a `prerelease` entry like
any other; the item is filed in each of their `todo.txt`. So today the entry is
VISIBLE in every client and merely not selected. `docs/CATALOG_SCHEMA.md` §2.3.1
is the contract they will implement against. This is why guard 3 - never the
default - matters more than the flag: it is the one that is actually running.

**A BANK-0 CHANGE CANNOT TOUCH ONLY NEW VERSIONS.** `build_all.sh` rebuilds
every carried version from the one `src/emu_hbios.asm`, so any change to it
re-cuts 3.5.1 and 3.6.0 as well - whose tags are immutable and whose assets are
already served. That is not a hypothetical: the ROM_SIG fix was applied on
2026-09-18, everything rebuilt, and `publish_release.sh` refused the re-cut by
name. The guard worked. Such a change lands only when the affected versions
stop being carried, or with a `v1` bump that re-cuts everything by design;
romwbw_emu `DECISIONS.md` #8 carries that one.

**RETIRE THE SNAPSHOT WHEN ITS RELEASE SHIPS.** The day upstream cuts a real
`v3.7.0`, the index would carry two entries whose `hbios` blocks are byte-
identical, and a client narrowing by those two bytes - the documented use, and
what every pre-2026-09-17 binary does - matches both with no rule to choose
between them. Nothing in the tooling detects that, because each entry is
individually correct.

So when the release lands: add `versions/3.7.0/`, delete
`versions/3.7.0-dev.14/` and `catalog/v0/3.7.0-dev.14/`, and regenerate. The
entry leaves the index and clients stop seeing it. The immutable
`v0-romwbw-3.7.0-dev.14` release tag stays live, so anything already pointing
at those assets keeps working - which is the whole reason per-version tags are
immutable. The same applies between snapshots: carry one at a time unless there
is a reason not to, or the index accumulates half a gigabyte of superseded
development builds.

**Do not name a version directory `3.7.0` for a snapshot.** That is the one
move that breaks everything above at once: the banner assertion would fail, the
asset names would collide with the real release when it ships, and the tag
`v0-romwbw-3.7.0` would be taken by something that is not 3.7.0.

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

All three - `src/r8.asm`, `src/w8.asm` and `src/emu_hbios.asm` - must stay
byte-identical to romwbw_emu's. `emu_hbios.asm` used to be the exception,
differing by its generated `romwbw_ver.inc` parameterisation, because that tree
hardcoded the release it was cut from; romwbw_emu v1.44 parameterised its copy
too, so plain equality is the check now. `src/emu_rom.asm` was a fourth shared
source until 69d2a71 deleted it from here: nothing in either repository builds
it, it carries no `.z80` directive so it does not assemble, and romwbw_emu keeps
the one remaining copy.
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
by the index's `help` block with a size and a sha256 each. **Three** clients read
them from the catalog - ioscpm, cpmdroid and z80cpmw. romwbw_emu, the fourth
client and the reference one, has no help subsystem at all: `tools/romwbw-get`
fetches ROMs and disks and nothing else.

Two of the three also bundle a copy as an offline floor - ioscpm's
`release_assets/` (which z80cpmw's `.rc` also compiles from) and cpmdroid's
`app/src/main/assets/help/`. Rewriting a topic here leaves those stale until
they are refreshed. ioscpm's `tools/check-help-assets.py` notices for the
ioscpm/z80cpmw pair; **cpmdroid's bundled copy is covered by nothing**, so a
rewritten topic leaves the Android offline floor stale silently.

## todo.txt

**Things to do, and nothing else.** Not history, not a settled decision, not a
standing fact, not a measurement, not a paragraph explaining that an item closed.
A closed item is DELETED. Finished work is in the commit message that finished
it; standing rules are in this file; what was measured about the old system is in
docs/FINDINGS.md.

**One or two lines an item.** If an item needs five paragraphs to justify itself,
the justification belongs in the document that carries the reasoning and the item
belongs in one line pointing at it.

**This repository only.** Work that would be done in `romwbw_emu`, `ioscpm`,
`cpmdroid`, `z80cpmw` or `cpmemu` goes in THAT repository's `todo.txt`, where the
session that can close it will read it. `romwbw_emu/todo.txt` states the
reciprocal rule; filing across it makes a list nobody acts on. A cross-repository
*consequence* is different from a cross-repository *task* and belongs in the doc
that carries the contract.

**It should be empty, and emptiest just after a release.** This repository
publishes; the gap between committed and published is one asset upload wide
(`sh tools/unreleased.sh`). If the file is longer at the end of a session than at
the start, that session did not do its job. It had reached 196 lines of mostly
history by 2026-09-18, when it was cut to one item - by doing the work, not by
describing it better.

## Before claiming what is shipped

Every "shipped", "wired in" or "under construction" sentence in this repository
describes the tree, and the tree does not know what a user can install. That is
the same failure `tools/check-store-version.sh` exists for in the clients. This
README said "Nothing here is wired into a shipping client yet" for some time
after all four clients had migrated. Measure before writing such a sentence, and
prefer not writing one.

## What is committed but not published

`sh tools/unreleased.sh` reports the gap that matters most in this family,
because it is the shortest: clients compile in one URL and read everything else
out of documents published here, so a catalog published in this repository
reaches ALREADY-INSTALLED clients on their next fetch, with no release of any app
on any platform. The gap between committed and published is one asset upload
wide.

It compares the published `index-v0.json` with `catalog/v0/index.json`, then
follows each `catalog_url` **out of the published index** — resolving the address
the way a client does rather than constructing it — and compares each
per-release catalog and each help topic against what is actually served.

**Do not add it to `verify.yml`.** That workflow builds and tests this
repository, which is what CI is for; what a release channel is serving is not.
Four jobs asking that question across this family were deleted on 2026-09-13.
No exit 1: 0 even when the catalog has moved and not been published, 2 only when
it could not measure.
