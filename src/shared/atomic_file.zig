const std = @import("std");

/// Writes `bytes` to `<final_name>.tmp` in `dir`, flushes, then renames over
/// `final_name`. Rename is atomic on POSIX filesystems; on failure the old
/// file is untouched.
pub fn writeFileAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    final_name: []const u8,
    bytes: []const u8,
) !void {
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.tmp", .{final_name});
    defer allocator.free(tmp_name);

    const file = try dir.createFile(io, tmp_name, .{});
    var closed = false;
    errdefer {
        if (!closed) file.close(io);
        dir.deleteFile(io, tmp_name) catch {};
    }

    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(io);
    closed = true;

    try dir.rename(tmp_name, dir, final_name, io);
}

const testing = std.testing;

test "writeFileAtomic writes the final file and removes the temp file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(testing.allocator, testing.io, tmp.dir, "out.json", "{\"a\":1}");

    const bytes = try tmp.dir.readFileAlloc(testing.io, "out.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"a\":1}", bytes);

    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "out.json.tmp", testing.allocator, .limited(16)));
}

test "writeFileAtomic replaces existing content atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(testing.allocator, testing.io, tmp.dir, "out.json", "old");
    try writeFileAtomic(testing.allocator, testing.io, tmp.dir, "out.json", "new-content");

    const bytes = try tmp.dir.readFileAlloc(testing.io, "out.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("new-content", bytes);
}
