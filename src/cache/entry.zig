const std = @import("std");
const source_file_mod = @import("../assets/source_file.zig");
const AssetType = @import("../assets/asset.zig").AssetType;
const fnv1a = source_file_mod.fnv1a;
const SourceFile = source_file_mod.SourceFile;

pub const FLAG_ERRORED: u16 = 1 << 0;

pub const CacheEntry = struct {
    source_path: []const u8,
    source_path_hash: u64,
    content_hash: u64,
    source_size: u64,
    source_mtime: i96,
    cooked_path: []const u8,
    cooked_path_hash: u64,
    cooked_size: u64,
    cooked_at: i96,
    flags: u16 = 0,
    asset_type: AssetType,

    pub fn isErrored(self: *const CacheEntry) bool {
        return self.flags & FLAG_ERRORED != 0;
    }

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

        const now = std.Io.Clock.Timestamp.now(io, .real);

        return .{
            .source_path = owned_source,
            .source_path_hash = source_file.hashPath(),
            .content_hash = try source_file.hash(source_dir, io),
            .source_size = source_info.size,
            .source_mtime = source_info.modified_ns,
            .cooked_path = owned_cooked,
            .cooked_path_hash = fnv1a(cooked_path),
            .cooked_size = cooked_size,
            .cooked_at = now.raw.nanoseconds,
            .asset_type = source_file.assetType,
        };
    }

    pub fn createErrored(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        source_file: SourceFile,
    ) !CacheEntry {
        const source_info = try source_file.getFileInfo(source_dir, io);

        const owned_source = try allocator.dupe(u8, source_file.path);
        errdefer allocator.free(owned_source);
        const owned_cooked = try allocator.dupe(u8, "");

        return .{
            .source_path = owned_source,
            .source_path_hash = source_file.hashPath(),
            .content_hash = try source_file.hash(source_dir, io),
            .source_size = source_info.size,
            .source_mtime = source_info.modified_ns,
            .cooked_path = owned_cooked,
            .cooked_path_hash = 0,
            .cooked_size = 0,
            .cooked_at = 0,
            .flags = FLAG_ERRORED,
            .asset_type = source_file.assetType,
        };
    }
};

const testing = std.testing;

test "create populates all fields from source file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "hello world";
    const file = try tmp.dir.createFile(testing.io, "model.glb", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    file.close(testing.io);

    const source_file = SourceFile{
        .path = "model.glb",
        .extension = .glb,
        .assetType = .mesh,
    };

    const entry = try CacheEntry.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        source_file,
        "model.zmesh",
        256,
    );
    defer {
        testing.allocator.free(entry.source_path);
        testing.allocator.free(entry.cooked_path);
    }

    try testing.expectEqualStrings("model.glb", entry.source_path);
    try testing.expectEqual(fnv1a("model.glb"), entry.source_path_hash);
    try testing.expectEqual(@as(u64, content.len), entry.source_size);
    try testing.expectEqualStrings("model.zmesh", entry.cooked_path);
    try testing.expectEqual(fnv1a("model.zmesh"), entry.cooked_path_hash);
    try testing.expectEqual(@as(u64, 256), entry.cooked_size);
    try testing.expectEqual(AssetType.mesh, entry.asset_type);
    try testing.expect(entry.content_hash != 0);
    try testing.expect(entry.source_mtime != 0);
    try testing.expect(entry.cooked_at != 0);
}

test "create owns copies of paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "test.glb", .{});
    file.close(testing.io);

    var path_buf: [32]u8 = undefined;
    @memcpy(path_buf[0.."test.glb".len], "test.glb");
    const mutable_path: []const u8 = path_buf[0.."test.glb".len];

    const source_file = SourceFile{
        .path = mutable_path,
        .extension = .glb,
        .assetType = .mesh,
    };

    const entry = try CacheEntry.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        source_file,
        "out.zmesh",
        0,
    );
    defer {
        testing.allocator.free(entry.source_path);
        testing.allocator.free(entry.cooked_path);
    }

    try testing.expect(entry.source_path.ptr != mutable_path.ptr);
    try testing.expectEqualStrings("test.glb", entry.source_path);
}

test "create with unknown asset type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "data.bin", .{});
    file.close(testing.io);

    const source_file = SourceFile{
        .path = "data.bin",
        .extension = .other,
        .assetType = .unknown,
    };

    const entry = try CacheEntry.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        source_file,
        "data.cooked",
        0,
    );
    defer {
        testing.allocator.free(entry.source_path);
        testing.allocator.free(entry.cooked_path);
    }

    try testing.expectEqual(AssetType.unknown, entry.asset_type);
}
