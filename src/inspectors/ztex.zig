const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const ztex = @import("../formats/ztex.zig");
const cooked_texture = @import("../assets/cooked/texture.zig");
const raw_texture = @import("../assets/raw/texture.zig");

const TexelFormat = cooked_texture.TexelFormat;
const ColorSpace = raw_texture.ColorSpace;

const MIP_ENTRY_HEADER_SIZE: u32 = @sizeOf(u32) * 2; // width + height

fn formatName(f: TexelFormat) []const u8 {
    return switch (f) {
        .rgba8 => "rgba8",
        .rg8 => "rg8",
        .r8 => "r8",
        .rgb16f => "rgb16f",
        .bc4 => "bc4",
        .bc5 => "bc5",
        .bc7 => "bc7",
        .bc6h => "bc6h",
    };
}

fn colorSpaceName(c: ColorSpace) []const u8 {
    return switch (c) {
        .srgb => "srgb",
        .linear => "linear",
    };
}

fn textureTypeName(t: ztex.TextureType) []const u8 {
    return switch (t) {
        .texture_2d => "texture_2d",
        .texture_cube => "texture_cube",
        .texture_array => "texture_array",
    };
}

fn inspectZtex(_: std.mem.Allocator, reader: *std.Io.Reader) !void {
    const header = try ztex.ZatexHeader.read(reader);

    log.info("zatex v{d}", .{ztex.ZATEX_VERSION});
    log.info("  Dimensions: {d} x {d}", .{ header.width, header.height });
    log.info("  Type:       {s}", .{textureTypeName(header.texture_type)});
    log.info("  Format:     {s}", .{formatName(header.format)});
    log.info("  Color sp:   {s}", .{colorSpaceName(header.color_space)});
    log.info("  Mips:       {d}", .{header.mip_count});

    log.info("", .{});
    log.info("Mip Levels:", .{});
    log.info("  {s: >5}  {s: >8}  {s: >8}  {s: >10}", .{ "level", "width", "height", "size" });
    log.info("  {s}", .{"-" ** 40});

    var total_data_size: u64 = 0;

    for (0..header.mip_count) |i| {
        const width = try reader.takeInt(u32, .little);
        const height = try reader.takeInt(u32, .little);

        const size: u64 = @intCast(header.format.imageSize(width, height));
        total_data_size += size;
        try reader.discardAll(size);

        var size_buf: [16]u8 = undefined;
        const size_str = fmt.formatBytes(&size_buf, size);

        log.info("  {d: >5}  {d: >8}  {d: >8}  {s: >10}", .{ i, width, height, size_str });
    }

    const mip_meta_size: u64 = @as(u64, header.mip_count) * MIP_ENTRY_HEADER_SIZE;
    const total_file_size: u64 = ztex.HEADER_SIZE + mip_meta_size + total_data_size;

    log.info("", .{});
    log.info("File Size Summary:", .{});
    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    var buf3: [16]u8 = undefined;
    var buf4: [16]u8 = undefined;
    log.info("  Header:        {s: >10}", .{fmt.formatBytes(&buf1, ztex.HEADER_SIZE)});
    log.info("  Mip metadata:  {s: >10}", .{fmt.formatBytes(&buf2, mip_meta_size)});
    log.info("  Mip data:      {s: >10}", .{fmt.formatBytes(&buf3, total_data_size)});
    log.info("  Total:         {s: >10}", .{fmt.formatBytes(&buf4, total_file_size)});
}

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZtex };
}

const testing = std.testing;

test "inspector returns a valid FormatInspector" {
    const insp = inspector();
    try testing.expectEqual(@as(*const fn (std.mem.Allocator, *std.Io.Reader) anyerror!void, inspectZtex), insp.inspectFn);
}

test "inspectZtex runs without error on a minimal valid ztex payload" {
    var file_buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try writeTestZtex(&writer, .{});

    // Skip the 5-byte magic, just like the inspect dispatcher does.
    var reader = std.Io.Reader.fixed(file_buf[ztex.MAGIC.len..writer.end]);
    try inspectZtex(testing.allocator, &reader);
}

test "inspectZtex reports mip counts from the header" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try writeTestZtex(&writer, .{ .width = 4, .height = 4, .mips = &.{ .{ 4, 4 }, .{ 2, 2 }, .{ 1, 1 } } });

    var reader = std.Io.Reader.fixed(file_buf[ztex.MAGIC.len..writer.end]);
    try inspectZtex(testing.allocator, &reader);
}

const TestZtexOpts = struct {
    width: u32 = 1,
    height: u32 = 1,
    format: TexelFormat = .rgba8,
    texture_type: ztex.TextureType = .texture_2d,
    color_space: ColorSpace = .srgb,
    /// Each entry is (width, height); data is zero-filled to w * h * bpp.
    mips: []const [2]u32 = &.{.{ 1, 1 }},
};

fn writeTestZtex(writer: *std.Io.Writer, opts: TestZtexOpts) !void {
    try writer.writeAll(ztex.MAGIC);
    try writer.writeInt(u32, ztex.ZATEX_VERSION, .little);
    try writer.writeInt(u32, opts.width, .little);
    try writer.writeInt(u32, opts.height, .little);
    try writer.writeInt(u16, @intCast(opts.mips.len), .little);
    try writer.writeInt(u16, @intFromEnum(opts.format), .little);
    try writer.writeInt(u8, @intFromEnum(opts.texture_type), .little);
    try writer.writeInt(u8, @intFromEnum(opts.color_space), .little);

    for (opts.mips) |mip| {
        const w = mip[0];
        const h = mip[1];
        try writer.writeInt(u32, w, .little);
        try writer.writeInt(u32, h, .little);
        const bytes = opts.format.imageSize(w, h);
        for (0..bytes) |_| try writer.writeInt(u8, 0, .little);
    }
}
