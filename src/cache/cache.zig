const std = @import("std");

const source_file_mod = @import("../assets/source_file.zig");
const SourceFile = source_file_mod.SourceFile;
const fnv1a = source_file_mod.fnv1a;
const AssetType = @import("../assets/asset.zig").AssetType;

pub const VERSION = 1;
pub const MAGIC = "ZACHE";

pub const HEADER_SIZE: u32 = MAGIC.len + @sizeOf(u16) + @sizeOf(u32); // magic + version + entry_count

pub const CacheHeader = struct {
    version: u16 = VERSION,
    entry_count: u32,
};

pub const CacheEntry = struct {
    source_path: []const u8,
    source_path_hash: u64,
    content_hash: u64,
    source_size: u64,
    source_mtime: i96,
    cooked_path: []const u8,
    cooked_path_hash: u64,
    cooked_size: u64,
    asset_type: AssetType,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        source_file: SourceFile,
        cooked_path: []const u8,
        cooked_size: u64,
    ) !CacheEntry {
        const source_info = try source_file.getFileInfo(source_dir, io);

        const owned_source = try allocator.dupe(u8, source_file.path);
        errdefer allocator.free(owned_source);
        const owned_cooked = try allocator.dupe(u8, cooked_path);

        return .{
            .source_path = owned_source,
            .source_path_hash = source_file.hashPath(),
            .content_hash = try source_file.hash(source_dir, io),
            .source_size = source_info.size,
            .source_mtime = source_info.modified_ns,
            .cooked_path = owned_cooked,
            .cooked_path_hash = fnv1a(cooked_path),
            .cooked_size = cooked_size,
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

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.source_path);
            allocator.free(entry.cooked_path);
        }
        self.entries.deinit(allocator);
    }

    pub fn pushCacheEntry(self: *Cache, allocator: std.mem.Allocator, entry: CacheEntry) !void {
        try self.entries.append(allocator, entry);
        self.header.entry_count += 1;
    }

    pub fn write(self: *const Cache, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.createFile(io, "tmp.zcache", .{});

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        var io_writer = &writer.interface;

        try io_writer.writeAll(MAGIC);
        try io_writer.writeInt(u16, self.header.version, .little);
        try io_writer.writeInt(u32, self.header.entry_count, .little);

        for (self.entries.items) |entry| {
            try io_writer.writeInt(u64, entry.source_path_hash, .little);
            try io_writer.writeInt(u64, entry.content_hash, .little);
            try io_writer.writeInt(u64, entry.source_size, .little);
            try io_writer.writeInt(i96, entry.source_mtime, .little);
            try io_writer.writeInt(u64, entry.cooked_path_hash, .little);
            try io_writer.writeInt(u64, entry.cooked_size, .little);
            try io_writer.writeInt(u16, @intFromEnum(entry.asset_type), .little);
            try io_writer.writeInt(u16, @intCast(entry.source_path.len), .little);
            try io_writer.writeAll(entry.source_path);
            try io_writer.writeInt(u16, @intCast(entry.cooked_path.len), .little);
            try io_writer.writeAll(entry.cooked_path);
        }

        try io_writer.flush();
        file.close(io);

        try cwd.rename("tmp.zcache", cwd, ".zcache", io);
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Cache {
        const version = try reader.takeInt(u16, .little);
        if (version != VERSION) {
            return error.UnsupportedVersion;
        }

        const entry_count = try reader.takeInt(u32, .little);

        var entries: std.ArrayList(CacheEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.source_path);
                allocator.free(entry.cooked_path);
            }
            entries.deinit(allocator);
        }

        try entries.ensureTotalCapacity(allocator, entry_count);

        for (0..entry_count) |_| {
            const source_path_hash = try reader.takeInt(u64, .little);
            const content_hash = try reader.takeInt(u64, .little);
            const source_size = try reader.takeInt(u64, .little);
            const source_mtime = try reader.takeInt(i96, .little);
            const cooked_path_hash = try reader.takeInt(u64, .little);
            const cooked_size = try reader.takeInt(u64, .little);
            const asset_type: AssetType = @enumFromInt(try reader.takeInt(u16, .little));

            const source_path_len = try reader.takeInt(u16, .little);
            const source_path = try allocator.alloc(u8, source_path_len);
            errdefer allocator.free(source_path);
            try reader.readSliceAll(source_path);

            const cooked_path_len = try reader.takeInt(u16, .little);
            const cooked_path = try allocator.alloc(u8, cooked_path_len);
            errdefer allocator.free(cooked_path);
            try reader.readSliceAll(cooked_path);

            entries.appendAssumeCapacity(.{
                .source_path = source_path,
                .source_path_hash = source_path_hash,
                .content_hash = content_hash,
                .source_size = source_size,
                .source_mtime = source_mtime,
                .cooked_path = cooked_path,
                .cooked_path_hash = cooked_path_hash,
                .cooked_size = cooked_size,
                .asset_type = asset_type,
            });
        }

        return .{
            .header = .{
                .version = version,
                .entry_count = entry_count,
            },
            .entries = entries,
            .source_dir = .cwd(),
        };
    }
};
