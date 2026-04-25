const std = @import("std");

const Zatex = @import("../formats/ztex.zig").Zatex;
const RawTexture = @import("../assets/raw/texture.zig").RawTexture;
const CookedTexture = @import("../assets/cooked/texture.zig").CookedTexture;
const file_read = @import("../shared/file_read.zig");

const Cooker = @import("cooker.zig").Cooker;

pub fn cooker() Cooker {
    return .{ .cookFn = cookObj, .asset_type = .texture };
}

fn cookObj(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    const raw = try RawTexture.init(file_path, file_result.bytes, allocator);
    defer raw.deinit(allocator);

    var cooked = try CookedTexture.cook(allocator, &raw);
    defer cooked.deinit(allocator);

    try Zatex.write(writer, cooked);
}
