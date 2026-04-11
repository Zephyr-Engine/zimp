const std = @import("std");
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const CacheEntry = @import("entry.zig").CacheEntry;

pub const Staleness = enum {
    cached,
    hash_match,
    stale_size,
    stale_content,
    errored,
    not_cached,

    pub fn check(io: std.Io, source_dir: std.Io.Dir, cache_entry: *const CacheEntry, source_file: *const SourceFile) !Staleness {
        if (cache_entry.isErrored()) {
            return .errored;
        }

        const source_file_info = try source_file.getFileInfo(source_dir, io);
        if (cache_entry.source_mtime == source_file_info.modified_ns) {
            return .cached;
        }

        if (cache_entry.source_size != source_file_info.size) {
            return .stale_size;
        }

        const source_content_hash = try source_file.hash(source_dir, io);
        if (cache_entry.content_hash != source_content_hash) {
            return .stale_content;
        }

        return .hash_match;
    }
};

const testing = std.testing;

fn createTestFile(tmp: std.testing.TmpDir, name: []const u8, content: []const u8) !void {
    const file = try tmp.dir.createFile(testing.io, name, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    file.close(testing.io);
}

fn makeSourceFile(path: []const u8) SourceFile {
    return .{ .path = path, .extension = .glb, .assetType = .mesh };
}

fn makeCacheEntryFromFile(tmp: std.testing.TmpDir, sf: *const SourceFile) !CacheEntry {
    const info = try sf.getFileInfo(tmp.dir, testing.io);
    const content_hash = try sf.hash(tmp.dir, testing.io);
    return .{
        .source_path = sf.path,
        .source_path_hash = sf.hashPath(),
        .content_hash = content_hash,
        .source_size = info.size,
        .source_mtime = info.modified_ns,
        .cooked_path = "out.zmesh",
        .cooked_path_hash = 0,
        .cooked_size = 0,
        .cooked_at = 0,
        .asset_type = .mesh,
    };
}

test "check returns cached when mtime matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    const entry = try makeCacheEntryFromFile(tmp, &sf);

    const result = try Staleness.check(testing.io, tmp.dir, &entry, &sf);
    try testing.expectEqual(Staleness.cached, result);
}

test "check returns stale_size when size differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.source_mtime = 0;
    entry.source_size = 999;

    const result = try Staleness.check(testing.io, tmp.dir, &entry, &sf);
    try testing.expectEqual(Staleness.stale_size, result);
}

test "check returns stale_content when size matches but hash differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.source_mtime = 0;
    entry.content_hash = 0xDEAD;

    const result = try Staleness.check(testing.io, tmp.dir, &entry, &sf);
    try testing.expectEqual(Staleness.stale_content, result);
}

test "check returns hash_match when size and hash match but mtime differs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFile(tmp, "a.glb", "hello");
    const sf = makeSourceFile("a.glb");
    var entry = try makeCacheEntryFromFile(tmp, &sf);
    entry.source_mtime = 0;

    const result = try Staleness.check(testing.io, tmp.dir, &entry, &sf);
    try testing.expectEqual(Staleness.hash_match, result);
}
