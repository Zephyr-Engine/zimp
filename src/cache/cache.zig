const std = @import("std");

const SourceFile = @import("../assets/source_file.zig").SourceFile;
const AssetType = @import("../assets/asset.zig").AssetType;

pub const VERSION = 1;
pub const MAGIC = "ZACH";

pub const CacheHeader = packed struct {
    magic: [4]u8 = MAGIC.*,
    version: u16 = VERSION,
    entry_count: u32,
};

pub const CacheEntry = struct {
    source_path_hash: u64,
    content_hash: u64,
    source_size: u64,
    source_mtime: i64,
    cooked_path_hash: u64,
    cooked_size: u64,
    asset_type: AssetType,

    pub fn create(
        io: std.Io,
        source_dir: std.Io.Dir,
        source_file: SourceFile,
    ) !CacheEntry {
        const source_info = try source_file.getFileInfo(source_dir, io);

        return .{
            .source_path_hash = source_file.hashPath(),
            .content_hash = 0,
            .source_size = source_info.size,
            .source_mtime = source_info.modified_ns,
            .cooked_path_hash = 0,
            .cooked_size = 0,
            .asset_type = source_file.assetType,
        };
    }
};

pub const Cache = struct {
    header: CacheHeader,
    entries: std.ArrayList(CacheEntry),
    source_dir: std.Io.Dir,

    pub fn init(source_dir: std.Io.Dir) Cache {
        return .{
            .header = .{
                .entry_count = 0,
            },
            .entries = .empty,
            .source_dir = source_dir,
        };
    }

    pub fn pushCacheEntry(self: *Cache, entry: CacheEntry) void {
        self.entries = self.entries.append(entry);
        self.header.entry_count += 1;
    }

    pub fn write(self: *const Cache, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, "tmp.zcache", .{
            .mode = .write_only,
        });

        var buf: [4096]u8 = undefined;
        const writer = file.writer(io, &buf);
        const io_writer = &writer.interface;

        try io_writer.writeAll(self.header);

        for (self.entries) |entry| {
            try io_writer.writeInt(u64, entry.source_path_hash, .little);
            try io_writer.writeInt(u64, entry.content_hash, .little);
            try io_writer.writeInt(u64, entry.source_size, .little);
            try io_writer.writeInt(i64, entry.source_mtime, .little);
            try io_writer.writeInt(i64, entry.cook_timestamp, .little);
            try io_writer.writeInt(u64, entry.cooked_path_hash, .little);
            try io_writer.writeInt(u32, entry.cooked_size, .little);
            try io_writer.writeInt(u16, entry.asset_type, .little);
        }

        try io_writer.flush();
        file.close(io);

        try cwd.rename("tmp.zcache", cwd, ".zcache", io);
    }
};
