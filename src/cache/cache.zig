const std = @import("std");

const source_file_mod = @import("../assets/source_file.zig");
const AssetType = @import("../assets/asset.zig").AssetType;
const CacheEntry = @import("entry.zig").CacheEntry;
const fnv1a = source_file_mod.fnv1a;
const SourceFile = source_file_mod.SourceFile;

pub const VERSION = 1;
pub const MAGIC = "ZACHE";

pub const HEADER_SIZE: u32 = MAGIC.len + @sizeOf(u16) + @sizeOf(u32); // magic + version + entry_count

pub const CacheHeader = struct {
    version: u16 = VERSION,
    entry_count: u32,
};

const EntryMap = std.AutoHashMap(u64, u32); // path_hash -> entry index

pub const Cache = struct {
    header: CacheHeader,
    entries: std.ArrayList(CacheEntry),
    entry_map: EntryMap,
    source_dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, source_dir: std.Io.Dir) Cache {
        return .{
            .header = .{
                .entry_count = 0,
            },
            .entry_map = .init(allocator),
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
        self.entry_map.deinit();
    }

    pub fn pushCacheEntry(self: *Cache, allocator: std.mem.Allocator, entry: CacheEntry) !void {
        try self.entries.append(allocator, entry);
        self.header.entry_count += 1;
    }

    pub fn overWriteCacheEntry(self: *Cache, allocator: std.mem.Allocator, entry: CacheEntry, idx: u32) !void {
        try self.entries.insert(allocator, idx, entry);
    }

    pub fn lookupEntry(self: *const Cache, source_file: SourceFile) ?*const CacheEntry {
        const path_hash = source_file.hashPath();
        if (self.entry_map.get(path_hash)) |entry_idx| {
            return &self.entries.items[entry_idx];
        }

        return null;
    }

    pub fn lookupEntryMut(self: *Cache, source_file: SourceFile) ?*CacheEntry {
        const path_hash = source_file.hashPath();
        if (self.entry_map.get(path_hash)) |entry_idx| {
            return &self.entries.items[entry_idx];
        }

        return null;
    }

    pub fn getIdx(self: *const Cache, source_file: SourceFile) ?u32 {
        const path_hash = source_file.hashPath();
        return self.entry_map.get(path_hash);
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

    pub fn readFromDir(allocator: std.mem.Allocator, io: std.Io, source_dir: std.Io.Dir) !Cache {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, ".zcache", .{});
        defer file.close(io);

        var buf: [8192]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        var reader = &file_reader.interface;

        var magic: [MAGIC.len]u8 = undefined;
        _ = try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) {
            return error.InvalidMagic;
        }

        var cache = try read(allocator, reader);
        cache.source_dir = source_dir;
        return cache;
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

        var entry_map: EntryMap = .init(allocator);
        try entry_map.ensureTotalCapacity(@intCast(entry_count));
        for (entries.items, 0..) |entry, i| {
            entry_map.putAssumeCapacity(entry.source_path_hash, @intCast(i));
        }

        return .{
            .header = .{
                .version = version,
                .entry_count = entry_count,
            },
            .entry_map = entry_map,
            .entries = entries,
            .source_dir = .cwd(),
        };
    }
};

const testing = std.testing;

fn makeTestEntry(allocator: std.mem.Allocator, source_path: []const u8, cooked_path: []const u8) !CacheEntry {
    const owned_source = try allocator.dupe(u8, source_path);
    errdefer allocator.free(owned_source);
    const owned_cooked = try allocator.dupe(u8, cooked_path);
    return .{
        .source_path = owned_source,
        .source_path_hash = fnv1a(source_path),
        .content_hash = 0xDEADBEEF,
        .source_size = 1024,
        .source_mtime = 1775606400 * std.time.ns_per_s,
        .cooked_path = owned_cooked,
        .cooked_path_hash = fnv1a(cooked_path),
        .cooked_size = 512,
        .asset_type = .mesh,
    };
}

fn writeTestCache(writer: *std.Io.Writer, entries: []const CacheEntry) !void {
    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    try writer.writeInt(u32, @intCast(entries.len), .little);

    for (entries) |entry| {
        try writer.writeInt(u64, entry.source_path_hash, .little);
        try writer.writeInt(u64, entry.content_hash, .little);
        try writer.writeInt(u64, entry.source_size, .little);
        try writer.writeInt(i96, entry.source_mtime, .little);
        try writer.writeInt(u64, entry.cooked_path_hash, .little);
        try writer.writeInt(u64, entry.cooked_size, .little);
        try writer.writeInt(u16, @intFromEnum(entry.asset_type), .little);
        try writer.writeInt(u16, @intCast(entry.source_path.len), .little);
        try writer.writeAll(entry.source_path);
        try writer.writeInt(u16, @intCast(entry.cooked_path.len), .little);
        try writer.writeAll(entry.cooked_path);
    }
}

// ── Cache.init ──

test "init returns empty cache" {
    const c = Cache.init(testing.allocator, .cwd());
    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
    try testing.expectEqual(VERSION, c.header.version);
}

// ── Cache.deinit ──

test "deinit frees allocated entry paths" {
    var c = Cache.init(testing.allocator, .cwd());
    const entry = try makeTestEntry(testing.allocator, "src/model.glb", "model.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    c.deinit(testing.allocator);
    // testing.allocator will panic if any memory is leaked
}

test "deinit on empty cache does not error" {
    var c = Cache.init(testing.allocator, .cwd());
    c.deinit(testing.allocator);
}

// ── pushCacheEntry ──

test "pushCacheEntry adds entry and increments count" {
    var c = Cache.init(testing.allocator, .cwd());
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);

    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    try testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
}

test "pushCacheEntry multiple entries" {
    var c = Cache.init(testing.allocator, .cwd());
    defer c.deinit(testing.allocator);

    for (0..5) |_| {
        const entry = try makeTestEntry(testing.allocator, "mesh.glb", "mesh.zmesh");
        try c.pushCacheEntry(testing.allocator, entry);
    }

    try testing.expectEqual(@as(u32, 5), c.header.entry_count);
    try testing.expectEqual(@as(usize, 5), c.entries.items.len);
}

// ── Cache.read ──

test "read parses single entry with all fields" {
    const source = "meshes/cube.glb";
    const cooked = "cube.zmesh";

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const entry = CacheEntry{
        .source_path = source,
        .source_path_hash = 0xAAAA,
        .content_hash = 0xBBBB,
        .source_size = 2048,
        .source_mtime = 999_000_000_000,
        .cooked_path = cooked,
        .cooked_path_hash = 0xCCCC,
        .cooked_size = 1024,
        .asset_type = .mesh,
    };
    try writeTestCache(&writer, &.{entry});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    const e = c.entries.items[0];
    try testing.expectEqual(@as(u64, 0xAAAA), e.source_path_hash);
    try testing.expectEqual(@as(u64, 0xBBBB), e.content_hash);
    try testing.expectEqual(@as(u64, 2048), e.source_size);
    try testing.expectEqual(@as(i96, 999_000_000_000), e.source_mtime);
    try testing.expectEqual(@as(u64, 0xCCCC), e.cooked_path_hash);
    try testing.expectEqual(@as(u64, 1024), e.cooked_size);
    try testing.expectEqual(AssetType.mesh, e.asset_type);
    try testing.expectEqualStrings(source, e.source_path);
    try testing.expectEqualStrings(cooked, e.cooked_path);
}

test "read parses multiple entries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const entries = [_]CacheEntry{
        .{
            .source_path = "a.glb",
            .source_path_hash = 1,
            .content_hash = 2,
            .source_size = 100,
            .source_mtime = 0,
            .cooked_path = "a.zmesh",
            .cooked_path_hash = 3,
            .cooked_size = 50,
            .asset_type = .mesh,
        },
        .{
            .source_path = "b.gltf",
            .source_path_hash = 4,
            .content_hash = 5,
            .source_size = 200,
            .source_mtime = 0,
            .cooked_path = "b.zmesh",
            .cooked_path_hash = 6,
            .cooked_size = 75,
            .asset_type = .unknown,
        },
    };
    try writeTestCache(&writer, &entries);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), c.header.entry_count);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
    try testing.expectEqualStrings("b.gltf", c.entries.items[1].source_path);
    try testing.expectEqual(AssetType.mesh, c.entries.items[0].asset_type);
    try testing.expectEqual(AssetType.unknown, c.entries.items[1].asset_type);
}

test "read accepts zero entries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, &.{});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
}

test "read returns UnsupportedVersion for wrong version" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, 999, .little);
    try writer.writeInt(u32, 0, .little);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.UnsupportedVersion, Cache.read(testing.allocator, &reader));
}

test "read handles entry with empty paths" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const entry = CacheEntry{
        .source_path = "",
        .source_path_hash = 0,
        .content_hash = 0,
        .source_size = 0,
        .source_mtime = 0,
        .cooked_path = "",
        .cooked_path_hash = 0,
        .cooked_size = 0,
        .asset_type = .unknown,
    };
    try writeTestCache(&writer, &.{entry});

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c = try Cache.read(testing.allocator, &reader);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), c.entries.items[0].source_path.len);
    try testing.expectEqual(@as(usize, 0), c.entries.items[0].cooked_path.len);
}

test "read errors on truncated entry data" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    try writer.writeInt(u32, 1, .little);
    // write only source_path_hash, then stop — truncated
    try writer.writeInt(u64, 0xAAAA, .little);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.EndOfStream, Cache.read(testing.allocator, &reader));
}

test "read errors on truncated header" {
    var buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    // missing entry_count

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.EndOfStream, Cache.read(testing.allocator, &reader));
}

// ── Write + Read round-trip ──

test "write then read round-trip preserves all fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a cache with entries
    var c = Cache.init(testing.allocator, tmp.dir);
    defer c.deinit(testing.allocator);

    const entry1 = try makeTestEntry(testing.allocator, "models/hero.glb", "hero.zmesh");
    try c.pushCacheEntry(testing.allocator, entry1);

    var entry2 = try makeTestEntry(testing.allocator, "models/tree.gltf", "tree.zmesh");
    entry2.content_hash = 0x12345678;
    entry2.source_size = 8192;
    entry2.cooked_size = 4096;
    entry2.asset_type = .unknown;
    try c.pushCacheEntry(testing.allocator, entry2);

    // Write to buffer
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, c.entries.items);

    // Read back
    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c2 = try Cache.read(testing.allocator, &reader);
    defer c2.deinit(testing.allocator);

    try testing.expectEqual(c.header.entry_count, c2.header.entry_count);

    for (c.entries.items, c2.entries.items) |original, parsed| {
        try testing.expectEqualStrings(original.source_path, parsed.source_path);
        try testing.expectEqual(original.source_path_hash, parsed.source_path_hash);
        try testing.expectEqual(original.content_hash, parsed.content_hash);
        try testing.expectEqual(original.source_size, parsed.source_size);
        try testing.expectEqual(original.source_mtime, parsed.source_mtime);
        try testing.expectEqualStrings(original.cooked_path, parsed.cooked_path);
        try testing.expectEqual(original.cooked_path_hash, parsed.cooked_path_hash);
        try testing.expectEqual(original.cooked_size, parsed.cooked_size);
        try testing.expectEqual(original.asset_type, parsed.asset_type);
    }
}

test "write then read round-trip with zero entries" {
    var c = Cache.init(testing.allocator, .cwd());
    defer c.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, c.entries.items);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    var c2 = try Cache.read(testing.allocator, &reader);
    defer c2.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), c2.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c2.entries.items.len);
}

// ── HEADER_SIZE ──

test "HEADER_SIZE matches expected layout" {
    // magic(5) + version(2) + entry_count(4) = 11
    try testing.expectEqual(@as(u32, MAGIC.len + @sizeOf(u16) + @sizeOf(u32)), HEADER_SIZE);
}
