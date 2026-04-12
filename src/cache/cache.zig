const std = @import("std");

const source_file_mod = @import("../assets/source_file.zig");
const AssetType = @import("../assets/asset.zig").AssetType;
const CacheEntry = @import("entry.zig").CacheEntry;
const fnv1a = source_file_mod.fnv1a;
const SourceFile = source_file_mod.SourceFile;
const log = @import("../logger.zig");

pub const VERSION = 2;
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
    output_dir_path: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, source_dir: std.Io.Dir, output_dir_path: []const u8) !Cache {
        return .{
            .header = .{
                .entry_count = 0,
            },
            .entry_map = .init(allocator),
            .entries = .empty,
            .source_dir = source_dir,
            .output_dir_path = try allocator.dupe(u8, output_dir_path),
        };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.source_path);
            allocator.free(entry.cooked_path);
        }
        self.entries.deinit(allocator);
        self.entry_map.deinit();
        allocator.free(self.output_dir_path);
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

    pub fn pruneDeleted(self: *Cache, allocator: std.mem.Allocator, source_files: []const SourceFile) u32 {
        var removed: u32 = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            var found = false;
            for (source_files) |sf| {
                if (sf.hashPath() == entry.source_path_hash) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                log.debug("Source file not found, removing cooked file {s}", .{entry.cooked_path});
                allocator.free(entry.source_path);
                allocator.free(entry.cooked_path);
                _ = self.entries.orderedRemove(i);
                _ = self.entry_map.remove(entry.source_path_hash);
                self.header.entry_count -= 1;
                removed += 1;
            } else {
                i += 1;
            }
        }

        // Rebuild entry_map indices after removals
        if (removed > 0) {
            self.entry_map.clearRetainingCapacity();
            for (self.entries.items, 0..) |entry, idx| {
                self.entry_map.putAssumeCapacity(entry.source_path_hash, @intCast(idx));
            }
        }

        return removed;
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
        try io_writer.writeInt(u16, @intCast(self.output_dir_path.len), .little);
        try io_writer.writeAll(self.output_dir_path);

        for (self.entries.items) |entry| {
            try io_writer.writeInt(u64, entry.source_path_hash, .little);
            try io_writer.writeInt(u64, entry.content_hash, .little);
            try io_writer.writeInt(u64, entry.source_size, .little);
            try io_writer.writeInt(i96, entry.source_mtime, .little);
            try io_writer.writeInt(u64, entry.cooked_path_hash, .little);
            try io_writer.writeInt(u64, entry.cooked_size, .little);
            try io_writer.writeInt(i96, entry.cooked_at, .little);
            try io_writer.writeInt(u16, entry.flags, .little);
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

    pub fn readFromDir(allocator: std.mem.Allocator, io: std.Io, source_dir: std.Io.Dir, output_dir_path: []const u8) !Cache {
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

        const version = try reader.takeInt(u16, .little);
        if (version == 0 or version > VERSION) {
            return error.UnsupportedVersion;
        }

        if (version < VERSION) {
            return error.StaleVersion;
        }

        var cache = try readEntries(allocator, version, reader);
        cache.source_dir = source_dir;

        if (!std.mem.eql(u8, cache.output_dir_path, output_dir_path)) {
            const old_output_dir_path = cache.output_dir_path;
            defer {
                cache.deinit(allocator);
            }

            if (old_output_dir_path.len > 0) {
                log.info("Output directory changed from '{s}' to '{s}', invalidating cache", .{ old_output_dir_path, output_dir_path });
                if (std.Io.Dir.openDir(cwd, io, old_output_dir_path, .{})) |old_output_dir| {
                    for (cache.entries.items) |entry| {
                        if (entry.cooked_path.len > 0) {
                            old_output_dir.deleteFile(io, entry.cooked_path) catch |err| {
                                log.warn("Failed to delete old cooked file '{s}' from '{s}': {s}", .{ entry.cooked_path, old_output_dir_path, @errorName(err) });
                            };
                        }
                    }
                } else |_| {
                    log.warn("Could not open old output directory '{s}' to clean up cooked files", .{old_output_dir_path});
                }
            }

            return error.OutputDirChanged;
        }

        return cache;
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Cache {
        const version = try reader.takeInt(u16, .little);
        if (version != VERSION) {
            return error.UnsupportedVersion;
        }

        return readEntries(allocator, version, reader);
    }

    fn readEntries(allocator: std.mem.Allocator, version: u16, reader: *std.Io.Reader) !Cache {
        const entry_count = try reader.takeInt(u32, .little);

        const output_dir_path_len = try reader.takeInt(u16, .little);
        const output_dir_path = try allocator.alloc(u8, output_dir_path_len);
        errdefer allocator.free(output_dir_path);
        try reader.readSliceAll(output_dir_path);

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
            const cooked_at = try reader.takeInt(i96, .little);
            const flags = try reader.takeInt(u16, .little);
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
                .cooked_at = cooked_at,
                .flags = flags,
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
            .output_dir_path = output_dir_path,
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
        .cooked_at = 1775606400 * std.time.ns_per_s,
        .asset_type = .mesh,
    };
}

fn writeTestCache(writer: *std.Io.Writer, entries: []const CacheEntry) !void {
    try writeTestCacheWithOutputDir(writer, entries, ".");
}

fn writeTestCacheWithOutputDir(writer: *std.Io.Writer, entries: []const CacheEntry, output_dir_path: []const u8) !void {
    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    try writer.writeInt(u32, @intCast(entries.len), .little);
    try writer.writeInt(u16, @intCast(output_dir_path.len), .little);
    try writer.writeAll(output_dir_path);

    for (entries) |entry| {
        try writer.writeInt(u64, entry.source_path_hash, .little);
        try writer.writeInt(u64, entry.content_hash, .little);
        try writer.writeInt(u64, entry.source_size, .little);
        try writer.writeInt(i96, entry.source_mtime, .little);
        try writer.writeInt(u64, entry.cooked_path_hash, .little);
        try writer.writeInt(u64, entry.cooked_size, .little);
        try writer.writeInt(i96, entry.cooked_at, .little);
        try writer.writeInt(u16, entry.flags, .little);
        try writer.writeInt(u16, @intFromEnum(entry.asset_type), .little);
        try writer.writeInt(u16, @intCast(entry.source_path.len), .little);
        try writer.writeAll(entry.source_path);
        try writer.writeInt(u16, @intCast(entry.cooked_path.len), .little);
        try writer.writeAll(entry.cooked_path);
    }
}

test "init returns empty cache" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
    try testing.expectEqual(VERSION, c.header.version);
}

test "deinit frees allocated entry paths" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    const entry = try makeTestEntry(testing.allocator, "src/model.glb", "model.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    c.deinit(testing.allocator);
}

test "deinit on empty cache does not error" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    c.deinit(testing.allocator);
}

test "pushCacheEntry adds entry and increments count" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);

    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    try testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
}

test "pushCacheEntry multiple entries" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    for (0..5) |_| {
        const entry = try makeTestEntry(testing.allocator, "mesh.glb", "mesh.zmesh");
        try c.pushCacheEntry(testing.allocator, entry);
    }

    try testing.expectEqual(@as(u32, 5), c.header.entry_count);
    try testing.expectEqual(@as(usize, 5), c.entries.items.len);
}

test "lookupEntry returns entry when path hash matches" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    try c.entry_map.put(entry.source_path_hash, 0);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    const found = c.lookupEntry(sf);
    try testing.expect(found != null);
    try testing.expectEqualStrings("a.glb", found.?.source_path);
}

test "lookupEntry returns null when not found" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "missing.glb", .extension = .glb, .assetType = .mesh };
    try testing.expect(c.lookupEntry(sf) == null);
}

test "lookupEntryMut returns mutable entry" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    try c.entry_map.put(entry.source_path_hash, 0);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    const found = c.lookupEntryMut(sf);
    try testing.expect(found != null);
    found.?.source_mtime = 42;
    try testing.expectEqual(@as(i96, 42), c.entries.items[0].source_mtime);
}

test "lookupEntryMut returns null when not found" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "missing.glb", .extension = .glb, .assetType = .mesh };
    try testing.expect(c.lookupEntryMut(sf) == null);
}

test "getIdx returns index when entry exists" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const entry = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, entry);
    try c.entry_map.put(entry.source_path_hash, 0);

    const sf = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    try testing.expectEqual(@as(u32, 0), c.getIdx(sf).?);
}

test "getIdx returns null when entry does not exist" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const sf = SourceFile{ .path = "missing.glb", .extension = .glb, .assetType = .mesh };
    try testing.expect(c.getIdx(sf) == null);
}

test "pruneDeleted removes entries not in source list" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path_hash, 0);

    const e2 = try makeTestEntry(testing.allocator, "b.glb", "b.zmesh");
    try c.pushCacheEntry(testing.allocator, e2);
    try c.entry_map.put(e2.source_path_hash, 1);

    const source_files = [_]SourceFile{
        .{ .path = "a.glb", .extension = .glb, .assetType = .mesh },
    };

    const removed = c.pruneDeleted(testing.allocator, &source_files);
    try testing.expectEqual(@as(u32, 1), removed);
    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
    try testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try testing.expectEqualStrings("a.glb", c.entries.items[0].source_path);
}

test "pruneDeleted returns zero when all entries present" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path_hash, 0);

    const source_files = [_]SourceFile{
        .{ .path = "a.glb", .extension = .glb, .assetType = .mesh },
    };

    const removed = c.pruneDeleted(testing.allocator, &source_files);
    try testing.expectEqual(@as(u32, 0), removed);
    try testing.expectEqual(@as(u32, 1), c.header.entry_count);
}

test "pruneDeleted removes all entries when source list is empty" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path_hash, 0);

    const e2 = try makeTestEntry(testing.allocator, "b.glb", "b.zmesh");
    try c.pushCacheEntry(testing.allocator, e2);
    try c.entry_map.put(e2.source_path_hash, 1);

    const empty: []const SourceFile = &.{};
    const removed = c.pruneDeleted(testing.allocator, empty);
    try testing.expectEqual(@as(u32, 2), removed);
    try testing.expectEqual(@as(u32, 0), c.header.entry_count);
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
}

test "pruneDeleted rebuilds entry_map with correct indices" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const e1 = try makeTestEntry(testing.allocator, "a.glb", "a.zmesh");
    try c.pushCacheEntry(testing.allocator, e1);
    try c.entry_map.put(e1.source_path_hash, 0);

    const e2 = try makeTestEntry(testing.allocator, "b.glb", "b.zmesh");
    try c.pushCacheEntry(testing.allocator, e2);
    try c.entry_map.put(e2.source_path_hash, 1);

    const e3 = try makeTestEntry(testing.allocator, "c.glb", "c.zmesh");
    try c.pushCacheEntry(testing.allocator, e3);
    try c.entry_map.put(e3.source_path_hash, 2);

    const source_files = [_]SourceFile{
        .{ .path = "a.glb", .extension = .glb, .assetType = .mesh },
        .{ .path = "c.glb", .extension = .glb, .assetType = .mesh },
    };

    _ = c.pruneDeleted(testing.allocator, &source_files);

    const sf_a = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    const sf_c = SourceFile{ .path = "c.glb", .extension = .glb, .assetType = .mesh };
    try testing.expectEqual(@as(u32, 0), c.getIdx(sf_a).?);
    try testing.expectEqual(@as(u32, 1), c.getIdx(sf_c).?);
}

test "pruneDeleted on empty cache returns zero" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
    defer c.deinit(testing.allocator);

    const empty: []const SourceFile = &.{};
    const removed = c.pruneDeleted(testing.allocator, empty);
    try testing.expectEqual(@as(u32, 0), removed);
}

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
        .cooked_at = 1775606400 * std.time.ns_per_s,
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
            .cooked_at = 0,
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
            .cooked_at = 0,
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
        .cooked_at = 0,
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
    try writer.writeInt(u16, 1, .little); // output_dir_path len
    try writer.writeAll("."); // output_dir_path
    try writer.writeInt(u64, 0xAAAA, .little);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.EndOfStream, Cache.read(testing.allocator, &reader));
}

test "read errors on truncated header" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    try testing.expectError(error.EndOfStream, Cache.read(testing.allocator, &reader));
}

test "write then read round-trip preserves all fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var c = try Cache.init(testing.allocator, tmp.dir, ".");
    defer c.deinit(testing.allocator);

    const entry1 = try makeTestEntry(testing.allocator, "models/hero.glb", "hero.zmesh");
    try c.pushCacheEntry(testing.allocator, entry1);

    var entry2 = try makeTestEntry(testing.allocator, "models/tree.gltf", "tree.zmesh");
    entry2.content_hash = 0x12345678;
    entry2.source_size = 8192;
    entry2.cooked_size = 4096;
    entry2.asset_type = .unknown;
    try c.pushCacheEntry(testing.allocator, entry2);

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestCache(&writer, c.entries.items);

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
        try testing.expectEqual(original.cooked_at, parsed.cooked_at);
        try testing.expectEqual(original.asset_type, parsed.asset_type);
    }
}

test "write then read round-trip with zero entries" {
    var c = try Cache.init(testing.allocator, .cwd(), ".");
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

test "HEADER_SIZE matches expected layout" {
    try testing.expectEqual(@as(u32, MAGIC.len + @sizeOf(u16) + @sizeOf(u32)), HEADER_SIZE);
}
