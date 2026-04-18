const std = @import("std");

pub const MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC.ZATEX;
pub const ZATEX_VERSION: u32 = 1;

const cooked_texture = @import("../assets/cooked/texture.zig");
const CookedTexture = cooked_texture.CookedTexture;
const TexelFormat = cooked_texture.TexelFormat;
const ColorSpace = @import("../assets/raw/texture.zig").ColorSpace;

pub const HEADER_SIZE: u32 = MAGIC.len // magic
+ @sizeOf(u32) // version
+ @sizeOf(u32) // width
+ @sizeOf(u32) // height
+ @sizeOf(u16) // mip_count
+ @sizeOf(u16) // texel_format
+ @sizeOf(u8) // texture_type
+ @sizeOf(u8) // color_space
+ @sizeOf(u32); // mip_table_offset

const TextureType = enum(u8) {
    texture_2d = 0,
    texture_cube = 1,
    texture_array = 2,
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

    pub fn init(cooked_tex: CookedTexture) ZatexHeader {
        return .{
            .width = cooked_tex.width,
            .height = cooked_tex.height,
            .mip_count = @intCast(cooked_tex.mips.len),
            .format = cooked_tex.format,
            .texture_type = .texture_2d,
            .color_space = cooked_tex.color_space,
            .mip_table_offset = HEADER_SIZE,
        };
    }

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

pub const Zatex = struct {
    width: u32,
    height: u32,
    format: TexelFormat,
    texture_type: TextureType,
    color_space: ColorSpace,
    mip_entries: []const MipEntry,

    pub const MipEntry = struct {
        offset: u32,
        width: u32,
        height: u32,
        data: []const u8,
    };

    pub fn read(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !Zatex {
        var buf: [8192]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const reader = &file_reader.interface;

        const header = try ZatexHeader.read(reader);
        const mip_entries = try allocator.alloc(MipEntry, header.mip_count);
        for (0..header.mip_count) |i| {
            const width = try reader.takeInt(u32, .little);
            const height = try reader.takeInt(u32, .little);
            const offset = try reader.takeInt(u32, .little);
            const data = try reader.take(offset);

            mip_entries[i] = .{
                .width = width,
                .height = height,
                .offset = offset,
                .data = data,
            };
        }

        return .{
            .width = header.width,
            .height = header.height,
            .format = header.format,
            .texture_type = header.texture_type,
            .color_space = header.color_space,
        };
    }

    pub fn deinit(self: *Zatex, allocator: std.mem.Allocator) void {
        allocator.free(self.mip_entries);
    }

    pub fn write(writer: *std.Io.Writer, cooked_tex: CookedTexture) !void {
        const header = ZatexHeader.init(cooked_tex);
        try header.write(writer);

        for (cooked_tex.mips) |mip| {
            try writer.writeInt(u32, mip.width, .little);
            try writer.writeInt(u32, mip.height, .little);
            try writer.writeInt(u32, @intCast(mip.data.len), .little);
            try writer.writeAll(mip.data);
        }
    }
};
