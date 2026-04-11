const AssetType = @import("../assets/asset.zig").AssetType;

pub const VERSION = 1;
pub const MAGIC = "ZACH";

pub const CacheHeader = struct {
    magic: [4]u8 = MAGIC.*,
    version: u16 = VERSION,
    entry_count: u32,
};

pub const CacheEntry = struct {
    source_path_hash: u64,
    content_hash: u64,
    source_size: u64,
    source_mtime: i64,
    cook_timestamp: i64,
    cooked_path_hash: u64,
    cooked_size: u64,
    asset_type: AssetType,
};
