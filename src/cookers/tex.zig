const std = @import("std");

pub const stb = @cImport({
    @cInclude("stb_image.h");
});

const Image = struct {
    width: u32,
    height: u32,
    channels: u32, // always 4 after decode (RGBA)
    pixels: []u8, // length = width * height * channels
};

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

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load_from_memory(
        file_bytes.ptr,
        @intCast(file_bytes.len),
        &width,
        &height,
        &channels,
        4,
    );
    defer stb.stbi_image_free(pixels);

    const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;

    const image = Image{
        .width = @as(u32, @intCast(width)),
        .height = @as(u32, @intCast(height)),
        .channels = 4,
        .pixels = pixels[0..len],
    };

    _ = image;
    _ = writer;
}
