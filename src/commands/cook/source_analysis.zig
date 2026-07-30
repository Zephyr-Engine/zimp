const std = @import("std");

const source_file_mod = @import("../../assets/source_file.zig");
pub const SourceFile = source_file_mod.SourceFile;
pub const Hash = source_file_mod.Hash;

/// The one owner of a source payload during a cook job.  Metadata is captured
/// by the planner; bytes and their hash are loaded lazily and retained for the
/// cooker and cache update to share.
pub const HashedSource = struct {
    allocator: std.mem.Allocator,
    source: SourceFile,
    info: SourceFile.FileInfo,
    bytes: ?[]u8 = null,
    content_hash: ?Hash = null,
    bytes_read: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, source: SourceFile, info: SourceFile.FileInfo) HashedSource {
        return .{ .allocator = allocator, .source = source, .info = info };
    }

    pub fn deinit(self: *HashedSource) void {
        if (self.bytes) |bytes| {
            self.allocator.free(bytes);
        }
        self.* = undefined;
    }

    pub fn ensureLoaded(self: *HashedSource, io: std.Io, source_dir: std.Io.Dir) !void {
        if (self.bytes != null) {
            return;
        }

        const file = try source_dir.openFile(io, self.source.path, .{});
        defer file.close(io);

        const bytes = try self.allocator.alloc(u8, @intCast(self.info.size));
        errdefer self.allocator.free(bytes);
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        try reader.interface.readSliceAll(bytes);

        self.bytes = bytes;
        self.bytes_read = @intCast(bytes.len);
        self.content_hash = std.hash.XxHash64.hash(0, bytes);
    }

    pub fn hash(self: *HashedSource, io: std.Io, source_dir: std.Io.Dir) !Hash {
        try self.ensureLoaded(io, source_dir);
        return self.content_hash.?;
    }

    pub fn data(self: *HashedSource, io: std.Io, source_dir: std.Io.Dir) ![]const u8 {
        try self.ensureLoaded(io, source_dir);
        return self.bytes.?;
    }
};

const testing = std.testing;

test "HashedSource retains one payload and hash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "source.txt", .{});
    var write_buf: [32]u8 = undefined;
    var writer = file.writer(testing.io, &write_buf);
    try writer.interface.writeAll("retained bytes");
    try writer.interface.flush();
    file.close(testing.io);

    const source = SourceFile.fromPath("source.txt");
    var analyzed = HashedSource.init(testing.allocator, source, try source.getFileInfo(tmp.dir, testing.io));
    defer analyzed.deinit();
    const bytes = try analyzed.data(testing.io, tmp.dir);
    try testing.expectEqualStrings("retained bytes", bytes);
    try testing.expectEqual(std.hash.XxHash64.hash(0, bytes), try analyzed.hash(testing.io, tmp.dir));
    try testing.expectEqual(@as(u64, bytes.len), analyzed.bytes_read);
}
