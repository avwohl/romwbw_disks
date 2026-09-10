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
`help` block naming `index_url` and `base_url`, and a client reads the location
out of that document — exactly as it reads `catalog_url` for a RomWBW release. So
this directory can be renamed, re-tagged or moved to another host by editing the
index generator, with no client release on any platform. That property is the
whole point of the catalog, and a compiled-in help URL would have quietly broken
it for the one subsystem nobody was looking at.

It also means a fork gets this for free: a client pointed at another index with
`$ROMWBW_INDEX_URL` reads that index's `help` block, so a test catalog can serve
its own help without patching anything.

## Editing

1. Edit the `.md` files here. `help_index.json` lists them; a topic is `id`,
   `title`, `description` and `filename`.
2. Keep `base_url` in `help_index.json` equal to the `help-v0` download URL. No
   current client reads it — they use the `base_url` from the catalog index's
   `help` block — but a document that names its own location must not lie about
   it.
3. Re-cut the tag with the eight files as its assets.

Clients also compile in a copy of all of this as an offline fallback, so a topic
edited here does not reach an installed client that cannot fetch. That fallback
is per-client and is not generated from this directory.
