/// Error taxonomy for the asset manifest and `.zmeta` sidecars. Defined once
/// so codec, builder, store, and runtime loaders agree on failure names.
pub const ManifestError = error{
    // codec
    InvalidManifestFormat,
    UnsupportedManifestVersion,
    CorruptManifest,
    // semantic validation
    DuplicateAssetId,
    DuplicateSourcePath,
    ZeroAssetId,
    InvalidAssetPath,
    UnknownAssetKind,
};

pub const MetaError = error{
    InvalidMetaFormat,
    UnsupportedMetaVersion,
    ZeroMetaId,
    CorruptMeta,
};
