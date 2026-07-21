# Asset identity

Project cooks assign an `AssetId` to every successfully cooked asset. Identity
is independent from incremental cache state and follows these rules in order:

1. Sources under `generated/` receive a deterministic ID derived from their
   normalized source path. Generated sources do not have sidecars.
2. An authored source with a valid adjacent `.zmeta` sidecar uses the ID stored
   in that sidecar.
3. A new authored source receives a random UUIDv4 and a new sidecar.

Sidecars are authored data and should be committed. Move a sidecar with its
source when renaming an asset. Deleting it assigns a new ID on the next
successful cook and breaks references to the old ID.

Duplicate IDs and corrupt sidecars fail the project cook. New sidecars are
written only after the asset manifest has been built and atomically published.
The generated `assets.zmanifest` is sorted by source path and should not be
committed.

The incremental cache is not identity data. Project caches live at
`.zephyr/.zcache`; directory-mode caches live at `<output>/.zcache`. Either can
be deleted without changing IDs preserved by authored sidecars.
