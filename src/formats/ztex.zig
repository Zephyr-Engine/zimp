const std = @import("std");

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZATEX;
pub const ZATEX_VERSION: u32 = 1;

pub const HEADER_SIZE: u32 = MAGIC.len // magic
+ @sizeOf(u32) // version
+ @sizeOf(u32) // width
+ @sizeOf(u32) // height
+ @sizeOf(u16) // mip_count
+ @sizeOf(u16) // texel_format
+ @sizeOf(u8) // texture_type
+ @sizeOf(u38) // color_space
+ @sizeOf(u32); // mip_table_offset

const TexelFormat = enum(u16) {
    rgba8 = 0, // uncompressed, 4 bytes per pixel
    rg8 = 1, // 2-channel uncompressed (for normal maps before BC5)
    r8 = 2, // single-channel uncompressed (before BC4)
    rgb16f = 3, // HDR, 6 bytes per pixel
    bc4 = 10, // 1-channel block compressed
    bc5 = 11, // 2-channel block compressed
    bc7 = 12, // 4-channel block compressed
    bc6h = 13, // HDR block compressed
};

const TextureType = enum(u8) {
    texture_2d = 0,
    texture_cube = 1,
    texture_array = 2,
};

const ColorSpace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const ZatexHeader = struct {
    magic: [5]u8 = MAGIC.*,
    version: u32 = ZATEX_VERSION,
    width: u32,
    height: u32,
    mip_count: u16,
    format: TexelFormat,
    texture_type: TextureType,
    color_space: ColorSpace,
    mip_table_offset: u32,

    pub fn read(reader: *std.Io.Reader) !ZatexHeader {
        var magic: [5]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) {
            return error.InvalidMagic;
        }

        const version = try reader.takeInt(u32, .little);
        if (version != ZATEX_VERSION) {
            return error.UnsupportedVersion;
        }

        const width = try reader.takeInt(u32, .little);
        const height = try reader.takeInt(u32, .little);
        const mip_count = try reader.takeInt(u16, .little);
        const format: TexelFormat = @enumFromInt(try reader.takeInt(u16, .little));
        const texture_type: TextureType = @enumFromInt(try reader.takeInt(u8, .little));
        const color_space: ColorSpace = @enumFromInt(try reader.takeInt(u8, .little));
        const mip_table_offset = try reader.takeInt(u32, .little);

        return .{
            .width = width,
            .height = height,
            .mip_count = mip_count,
            .format = format,
            .texture_type = texture_type,
            .color_space = color_space,
            .mip_table_offset = mip_table_offset,
        };
    }

    pub fn write(self: *const ZatexHeader, writer: *std.Io.Writer) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u32, self.version, .little);
        try writer.writeInt(u32, self.width, .little);
        try writer.writeInt(u32, self.height, .little);
        try writer.writeInt(u16, self.mip_count, .little);
        try writer.writeInt(u16, @intFromEnum(self.format), .little);
        try writer.writeInt(u8, @intFromEnum(self.texture_type), .little);
        try writer.writeInt(u8, @intFromEnum(self.color_space), .little);
        try writer.writeInt(u32, self.mip_table_offset, .little);
    }
};

const Zatex = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u8,

    pub const MipEntry = struct {
        offset: u32,
        size: u32,
        width: u16,
        height: u16,
    };
};
