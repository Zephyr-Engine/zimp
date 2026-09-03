const std = @import("std");

/// Read granularity. Every caller used the same value, so it is fixed here
/// rather than threaded through as an option.
const chunk_size: usize = 256 * 1024;

pub fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Read an entire file into a freshly allocated buffer. The caller owns it.
pub fn readFileAllocChunked(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);

    const size: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);

    var read_total: usize = 0;
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    while (read_total < size) {
        const remaining = size - read_total;
        const to_read = @min(remaining, chunk_size);
        const did_read = try reader.readSliceShort(bytes[read_total .. read_total + to_read]);
        if (did_read == 0) {
            return error.UnexpectedEndOfStream;
        }
        read_total += did_read;
    }

    return bytes;
}

const testing = std.testing;

test "readFileAllocChunked reads file content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "a.bin", .{});
    var write_buf: [128]u8 = undefined;
    var writer = file.writer(testing.io, &write_buf);
    try writer.interface.writeAll("hello chunked world");
    try writer.interface.flush();
    file.close(testing.io);

    const bytes = try readFileAllocChunked(testing.allocator, testing.io, tmp.dir, "a.bin");
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings("hello chunked world", bytes);
}

test "fileExists reports present and absent files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "present.txt", .{});
    file.close(testing.io);

    try testing.expect(fileExists(tmp.dir, testing.io, "present.txt"));
    try testing.expect(!fileExists(tmp.dir, testing.io, "absent.txt"));
}
