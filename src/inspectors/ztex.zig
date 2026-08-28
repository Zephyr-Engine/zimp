const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const ztex = @import("../formats/ztex.zig");
const cooked_texture = @import("../assets/cooked/texture.zig");
const raw_texture = @import("../assets/raw/texture.zig");

const TexelFormat = cooked_texture.TexelFormat;
const ColorSpace = raw_texture.ColorSpace;
const MIP_ENTRY_HEADER_SIZE: u32 = @sizeOf(u32) * 2;

fn formatName(format: TexelFormat) []const u8 {
    return @tagName(format);
}

fn colorSpaceName(color_space: ColorSpace) []const u8 {
    return @tagName(color_space);
}

fn textureTypeName(texture_type: ztex.TextureType) []const u8 {
    return @tagName(texture_type);
}

fn inspectZtex(allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
    var texture = try ztex.read(allocator, reader);
    defer texture.deinit(allocator);

    log.info("zatex v{d}", .{ztex.ZATEX_VERSION});
    log.info("  Dimensions: {d} x {d}", .{ texture.width, texture.height });
    log.info("  Type:       {s}", .{textureTypeName(texture.texture_type)});
    log.info("  Format:     {s}", .{formatName(texture.format)});
    log.info("  Color sp:   {s}", .{colorSpaceName(texture.color_space)});
    log.info("  Mips:       {d}", .{texture.mips.len});

    log.info("", .{});
    log.info("Mip Levels:", .{});
    log.info("  {s: >5}  {s: >8}  {s: >8}  {s: >10}", .{ "level", "width", "height", "size" });
    log.info("  {s}", .{"-" ** 40});

    var total_data_size: u64 = 0;
    for (texture.mips, 0..) |mip, i| {
        total_data_size += mip.data.len;
        var size_buf: [16]u8 = undefined;
        log.info("  {d: >5}  {d: >8}  {d: >8}  {s: >10}", .{
            i,
            mip.width,
            mip.height,
            fmt.formatBytes(&size_buf, mip.data.len),
        });
    }

    const mip_meta_size: u64 = texture.mips.len * MIP_ENTRY_HEADER_SIZE;
    const total_file_size: u64 = ztex.HEADER_SIZE + mip_meta_size + total_data_size;

    log.info("", .{});
    log.info("File Size Summary:", .{});
    var header_buf: [16]u8 = undefined;
    var metadata_buf: [16]u8 = undefined;
    var data_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    log.info("  Header:        {s: >10}", .{fmt.formatBytes(&header_buf, ztex.HEADER_SIZE)});
    log.info("  Mip metadata:  {s: >10}", .{fmt.formatBytes(&metadata_buf, mip_meta_size)});
    log.info("  Mip data:      {s: >10}", .{fmt.formatBytes(&data_buf, total_data_size)});
    log.info("  Total:         {s: >10}", .{fmt.formatBytes(&total_buf, total_file_size)});
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZtex };
}

test "inspectZtex uses the format reader" {
    var data = [_]u8{ 0, 0, 0, 0 };
    var mips = [_]cooked_texture.CookedMip{.{
        .width = 1,
        .height = 1,
        .data = &data,
    }};
    const cooked = cooked_texture.CookedTexture{
        .width = 1,
        .height = 1,
        .format = .rgba8,
        .color_space = .srgb,
        .mips = &mips,
    };

    var file_buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try ztex.write(&writer, cooked);

    var reader = std.Io.Reader.fixed(file_buf[0..writer.end]);
    try inspectZtex(std.testing.allocator, &reader);
}
