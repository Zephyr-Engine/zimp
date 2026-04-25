const std = @import("std");

pub const ChunkedReadOptions = struct {
    chunk_size: usize = 256 * 1024,
};

pub const ChunkedReadResult = struct {
    bytes: []u8,
    bytes_read: usize,
};

pub fn readFileAllocChunked(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    options: ChunkedReadOptions,
) !ChunkedReadResult {
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
        const to_read = @min(remaining, options.chunk_size);
        const did_read = try reader.readSliceShort(bytes[read_total .. read_total + to_read]);
        if (did_read == 0) {
            return error.UnexpectedEndOfStream;
        }
        read_total += did_read;
    }

    return .{
        .bytes = bytes,
        .bytes_read = read_total,
    };
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

    const result = try readFileAllocChunked(testing.allocator, testing.io, tmp.dir, "a.bin", .{
        .chunk_size = 4,
    });
    defer testing.allocator.free(result.bytes);

    try testing.expectEqual(@as(usize, 19), result.bytes_read);
    try testing.expectEqualStrings("hello chunked world", result.bytes);
}
