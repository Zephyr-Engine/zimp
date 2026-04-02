pub const VERSION = 1;

pub const CacheHeader = struct {
    magic: [4]u8 = "ZACH",
    version: u16 = VERSION,
    entry_count: u32,
    dep_table_offset: u64,
};
