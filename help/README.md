# In-app help content

The topics the clients show in their Help window, and the index that lists them.
Published as the assets of the mutable **`help-v0`** tag.

## Why these live here

Every client used to fetch this from `avwohl/ioscpm/releases/latest/download/`,
which meant ioscpm's Latest release stayed load-bearing for every port long after
the disk images had moved here. Migrating the catalog freed nothing there; moving
these files is what frees it.

## The tag is mutable, and no client knows its name

`help-v0` is re-cut whenever a topic changes. That is safe for the same reason
`catalog-v0` is safe: it carries only small text files, and nothing caches them
against a version.

**No client compiles in this tag, or any URL under it.** `index-v0.json` carries a
`help` block: a `base_url` and a `topics[]` of `id`, `filename`, `name`,
`description`, `size` and `sha256` — the same shape `disks[]` and `roms[]` already
had, so a topic is checked on arrival like a ROM or a disk. A client reads the
location out of that document, exactly as it reads `catalog_url` for a RomWBW
release. So this directory can be renamed, re-tagged or moved to another host by
editing the index generator, with no client release on any platform. That
property is the whole point of the catalog, and a compiled-in help URL would have
quietly broken it for the one subsystem nobody was looking at.

It said the block names an `index_url` and a `base_url`, pointing at a separate
`help_index.json`. That was the first version and it is gone: there is no second
document, and no `help_index.json` is published here at all.

It also means a fork gets this for free: a client pointed at another index with
`$ROMWBW_INDEX_URL` reads that index's `help` block, so a test catalog can serve
its own help without patching anything.

## Editing

1. Edit the `.md` files here. `topics.json` lists them; a topic is `id`, `name`,
   `description` and `filename`. Nothing else needs editing — `size` and
   `sha256` are **measured** by `tools/gen_catalog.py`, so they cannot be
   authored wrong, and `base_url` is built from `HELP_TAG` there.
2. Regenerate `index-v0.json` and re-cut this tag with the seven `.md` files as
   its assets. `topics.json` is source, not an asset: the index is the published
   form of what it says.
3. **Publish the index in the same round.** The sizes and hashes in it describe
   the files you just changed; a client checks a downloaded topic against them
   and falls back to its own copy when they disagree, so a re-cut tag with a
   stale index means every reader silently reads the version compiled into their
   app.
4. **Keep the Latest flag where it belongs.** This is a mutable tag and it must
   not be published as Latest: `releases/latest/download/index-v0.json` is the
   entry point every client compiles in. Cutting `help-v0` as Latest on
   2026-09-10 answered 404 there for every client in the world until the flag was
   put back. `tools/check_latest.py` fails the repository if it lands anywhere
   else.

Clients also compile in a copy of all of this as an offline fallback, so a topic
edited here does not reach an installed client that cannot fetch. That fallback
is per-client and is not generated from this directory.
