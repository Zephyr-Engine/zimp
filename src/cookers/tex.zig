const std = @import("std");
const Image = @import("../parsers/texture/texture.zig").Image;

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
    const file_bytes = try source_dir.readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(file_bytes);

    const image = Image.init(file_path, file_bytes);
    const mipmaps = try image.generateMipmaps(allocator);
    defer {
        for (mipmaps) |mip| {
            allocator.free(mip.pixels);
        }
        allocator.free(mipmaps);
    }

    _ = writer;
}
