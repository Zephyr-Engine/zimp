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
+ @sizeOf(u8); // color_space

pub const TextureType = enum(u8) {
    texture_2d = 0,
    texture_cube = 1,
    texture_array = 2,
};

pub const ZatexHeader = struct {
    magic: [5]u8 = MAGIC.*,
    version: u32 = ZATEX_VERSION,
    width: u32,
    height: u32,
    mip_count: u16,
    format: TexelFormat,
    texture_type: TextureType,
    color_space: ColorSpace,

    pub fn init(cooked_tex: CookedTexture) ZatexHeader {
        return .{
            .width = cooked_tex.width,
            .height = cooked_tex.height,
            .mip_count = @intCast(cooked_tex.mips.len),
            .format = cooked_tex.format,
            .texture_type = .texture_2d,
            .color_space = cooked_tex.color_space,
        };
    }

    pub fn read(reader: *std.Io.Reader) !ZatexHeader {
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

        return .{
            .width = width,
            .height = height,
            .mip_count = mip_count,
            .format = format,
            .texture_type = texture_type,
            .color_space = color_space,
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
    }
};

pub const Zatex = struct {
    width: u32,
    height: u32,
    format: TexelFormat,
    texture_type: TextureType,
    color_space: ColorSpace,
    mips: []Mip,

    pub const Mip = struct {
        width: u32,
        height: u32,
        data: []u8,
    };

    pub fn read(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !Zatex {
        var buf: [8192]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const reader = &file_reader.interface;

        var magic: [5]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) {
            return error.InvalidMagic;
        }

        const header = try ZatexHeader.read(reader);

        const mips = try allocator.alloc(Mip, header.mip_count);
        errdefer allocator.free(mips);

        var loaded: usize = 0;
        errdefer for (mips[0..loaded]) |mip| allocator.free(mip.data);

        for (0..header.mip_count) |i| {
            const width = try reader.takeInt(u32, .little);
            const height = try reader.takeInt(u32, .little);
            const size = header.format.imageSize(width, height);

            const data = try allocator.alloc(u8, size);
            errdefer allocator.free(data);
            try reader.readSliceAll(data);

            mips[i] = .{
                .width = width,
                .height = height,
                .data = data,
            };
            loaded += 1;
        }

        return .{
            .width = header.width,
            .height = header.height,
            .format = header.format,
            .texture_type = header.texture_type,
            .color_space = header.color_space,
            .mips = mips,
        };
    }

    pub fn deinit(self: *Zatex, allocator: std.mem.Allocator) void {
        for (self.mips) |mip| allocator.free(mip.data);
        allocator.free(self.mips);
    }

    pub fn write(writer: *std.Io.Writer, cooked_tex: CookedTexture) !void {
        const header = ZatexHeader.init(cooked_tex);
        try header.write(writer);

        for (cooked_tex.mips) |mip| {
            const expected = cooked_tex.format.imageSize(mip.width, mip.height);
            std.debug.assert(mip.data.len == expected);

            try writer.writeInt(u32, mip.width, .little);
            try writer.writeInt(u32, mip.height, .little);
            try writer.writeAll(mip.data);
        }
    }
};

const testing = std.testing;
const CookedMip = cooked_texture.CookedMip;

fn makeCookedTexture(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: TexelFormat,
    color_space: ColorSpace,
    mip_count: usize,
) !CookedTexture {
    const mips = try allocator.alloc(CookedMip, mip_count);
    errdefer allocator.free(mips);

    var allocated: usize = 0;
    errdefer for (mips[0..allocated]) |mip| allocator.free(mip.data);

    var w: u32 = width;
    var h: u32 = height;
    for (0..mip_count) |i| {
        const size = format.imageSize(w, h);
        const data = try allocator.alloc(u8, size);
        for (data, 0..) |*b, j| b.* = @intCast((i * 37 + j * 13) & 0xff);
        mips[i] = .{ .width = w, .height = h, .data = data };
        allocated += 1;
        w = @max(1, w / 2);
        h = @max(1, h / 2);
    }

    return .{
        .width = width,
        .height = height,
        .format = format,
        .color_space = color_space,
        .mips = mips,
    };
}

fn writeToBuffer(buf: []u8, cooked: CookedTexture) !usize {
    var writer = std.Io.Writer.fixed(buf);
    try Zatex.write(&writer, cooked);
    return writer.end;
}

fn writeCookedToTmpFile(tmp: *testing.TmpDir, cooked: CookedTexture) !std.Io.File {
    const file = try tmp.dir.createFile(testing.io, "test.ztex", .{});
    var buf: [8192]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try Zatex.write(&writer.interface, cooked);
    try writer.flush();
    file.close(testing.io);
    return try tmp.dir.openFile(testing.io, "test.ztex", .{});
}

fn readU32(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

fn readU16(buf: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, buf[offset..][0..2], .little);
}

test "MAGIC is ZATEX" {
    try testing.expectEqualSlices(u8, "ZATEX", MAGIC);
}

test "HEADER_SIZE equals 23" {
    try testing.expectEqual(@as(u32, 23), HEADER_SIZE);
}

test "ZatexHeader.init copies dimensions and format" {
    var cooked = try makeCookedTexture(testing.allocator, 8, 4, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);

    const header = ZatexHeader.init(cooked);

    try testing.expectEqual(@as(u32, 8), header.width);
    try testing.expectEqual(@as(u32, 4), header.height);
    try testing.expectEqual(TexelFormat.rgba8, header.format);
    try testing.expectEqual(ColorSpace.srgb, header.color_space);
    try testing.expectEqual(TextureType.texture_2d, header.texture_type);
}

test "ZatexHeader.init derives mip_count from mip slice length" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 3);
    defer cooked.deinit(testing.allocator);

    const header = ZatexHeader.init(cooked);

    try testing.expectEqual(@as(u16, 3), header.mip_count);
}

test "ZatexHeader has default magic and version" {
    var cooked = try makeCookedTexture(testing.allocator, 1, 1, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);

    const header = ZatexHeader.init(cooked);

    try testing.expectEqualSlices(u8, "ZATEX", &header.magic);
    try testing.expectEqual(ZATEX_VERSION, header.version);
}

test "ZatexHeader.write writes magic at offset 0" {
    var cooked = try makeCookedTexture(testing.allocator, 1, 1, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);
    const header = ZatexHeader.init(cooked);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqualSlices(u8, "ZATEX", buf[0..5]);
}

test "ZatexHeader.write writes version at offset 5" {
    var cooked = try makeCookedTexture(testing.allocator, 1, 1, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);
    const header = ZatexHeader.init(cooked);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(ZATEX_VERSION, readU32(&buf, 5));
}

test "ZatexHeader.write writes width and height at offsets 9 and 13" {
    var cooked = try makeCookedTexture(testing.allocator, 256, 128, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);
    const header = ZatexHeader.init(cooked);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(@as(u32, 256), readU32(&buf, 9));
    try testing.expectEqual(@as(u32, 128), readU32(&buf, 13));
}

test "ZatexHeader.write writes mip_count, format, texture_type, color_space at trailing offsets" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .rgb16f, .linear, 3);
    defer cooked.deinit(testing.allocator);
    const header = ZatexHeader.init(cooked);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(@as(u16, 3), readU16(&buf, 17));
    try testing.expectEqual(@as(u16, @intFromEnum(TexelFormat.rgb16f)), readU16(&buf, 19));
    try testing.expectEqual(@as(u8, @intFromEnum(TextureType.texture_2d)), buf[21]);
    try testing.expectEqual(@as(u8, @intFromEnum(ColorSpace.linear)), buf[22]);
}

test "ZatexHeader.write total output is HEADER_SIZE bytes" {
    var cooked = try makeCookedTexture(testing.allocator, 1, 1, .r8, .linear, 1);
    defer cooked.deinit(testing.allocator);
    const header = ZatexHeader.init(cooked);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(HEADER_SIZE, @as(u32, @intCast(writer.end)));
}

test "ZatexHeader.read parses fields written by write" {
    var cooked = try makeCookedTexture(testing.allocator, 64, 32, .rg8, .linear, 4);
    defer cooked.deinit(testing.allocator);
    const original = ZatexHeader.init(cooked);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try original.write(&writer);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    const parsed = try ZatexHeader.read(&reader);

    try testing.expectEqual(original.version, parsed.version);
    try testing.expectEqual(original.width, parsed.width);
    try testing.expectEqual(original.height, parsed.height);
    try testing.expectEqual(original.mip_count, parsed.mip_count);
    try testing.expectEqual(original.format, parsed.format);
    try testing.expectEqual(original.texture_type, parsed.texture_type);
    try testing.expectEqual(original.color_space, parsed.color_space);
}

test "ZatexHeader.read returns UnsupportedVersion on mismatched version" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.writeInt(u32, ZATEX_VERSION + 99, .little);
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u8, 0, .little);
    try writer.writeInt(u8, 0, .little);

    var reader = std.Io.Reader.fixed(buf[0..writer.end]);
    try testing.expectError(error.UnsupportedVersion, ZatexHeader.read(&reader));
}

test "Zatex.write emits header followed by mip dimensions and data" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 2, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);

    var buf: [256]u8 = undefined;
    const written = try writeToBuffer(&buf, cooked);

    const expected: usize = HEADER_SIZE + @sizeOf(u32) * 2 + 4 * 2 * 4;
    try testing.expectEqual(expected, written);

    try testing.expectEqualSlices(u8, "ZATEX", buf[0..5]);
    try testing.expectEqual(@as(u32, 4), readU32(&buf, HEADER_SIZE));
    try testing.expectEqual(@as(u32, 2), readU32(&buf, HEADER_SIZE + 4));
    try testing.expectEqualSlices(u8, cooked.mips[0].data, buf[HEADER_SIZE + 8 .. written]);
}

test "Zatex.write emits each mip in order with its own dimensions" {
    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .r8, .linear, 3);
    defer cooked.deinit(testing.allocator);

    var buf: [512]u8 = undefined;
    const written = try writeToBuffer(&buf, cooked);

    var off: usize = HEADER_SIZE;
    for (cooked.mips) |mip| {
        try testing.expectEqual(mip.width, readU32(&buf, off));
        try testing.expectEqual(mip.height, readU32(&buf, off + 4));
        off += 8;
        try testing.expectEqualSlices(u8, mip.data, buf[off .. off + mip.data.len]);
        off += mip.data.len;
    }
    try testing.expectEqual(written, off);
}

test "Zatex.read parses header fields from a written file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var cooked = try makeCookedTexture(testing.allocator, 16, 8, .rgba8, .srgb, 1);
    defer cooked.deinit(testing.allocator);

    const file = try writeCookedToTmpFile(&tmp, cooked);
    var ztex = try Zatex.read(testing.allocator, testing.io, file);
    defer ztex.deinit(testing.allocator);
    file.close(testing.io);

    try testing.expectEqual(@as(u32, 16), ztex.width);
    try testing.expectEqual(@as(u32, 8), ztex.height);
    try testing.expectEqual(TexelFormat.rgba8, ztex.format);
    try testing.expectEqual(ColorSpace.srgb, ztex.color_space);
    try testing.expectEqual(TextureType.texture_2d, ztex.texture_type);
}

test "Zatex.read reads all mip data and dimensions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var cooked = try makeCookedTexture(testing.allocator, 4, 4, .rg8, .linear, 3);
    defer cooked.deinit(testing.allocator);

    const file = try writeCookedToTmpFile(&tmp, cooked);
    var ztex = try Zatex.read(testing.allocator, testing.io, file);
    defer ztex.deinit(testing.allocator);
    file.close(testing.io);

    try testing.expectEqual(cooked.mips.len, ztex.mips.len);
    for (cooked.mips, ztex.mips) |src, dst| {
        try testing.expectEqual(src.width, dst.width);
        try testing.expectEqual(src.height, dst.height);
        try testing.expectEqualSlices(u8, src.data, dst.data);
    }
}

test "Zatex.read roundtrips an rgb16f texture" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var cooked = try makeCookedTexture(testing.allocator, 8, 4, .rgb16f, .linear, 2);
    defer cooked.deinit(testing.allocator);

    const file = try writeCookedToTmpFile(&tmp, cooked);
    var ztex = try Zatex.read(testing.allocator, testing.io, file);
    defer ztex.deinit(testing.allocator);
    file.close(testing.io);

    try testing.expectEqual(TexelFormat.rgb16f, ztex.format);
    try testing.expectEqual(ColorSpace.linear, ztex.color_space);
    try testing.expectEqual(@as(usize, 2), ztex.mips.len);
    try testing.expectEqualSlices(u8, cooked.mips[0].data, ztex.mips[0].data);
    try testing.expectEqualSlices(u8, cooked.mips[1].data, ztex.mips[1].data);
}

test "Zatex.read returns InvalidMagic on wrong magic bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "bad.ztex", .{});
    var buf: [64]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll("NOPE!");
    try writer.interface.writeInt(u32, ZATEX_VERSION, .little);
    try writer.flush();
    file.close(testing.io);

    const read_file = try tmp.dir.openFile(testing.io, "bad.ztex", .{});
    defer read_file.close(testing.io);

    try testing.expectError(error.InvalidMagic, Zatex.read(testing.allocator, testing.io, read_file));
}

test "Zatex.read returns UnsupportedVersion on bad version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "bad.ztex", .{});
    var buf: [64]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(MAGIC);
    try writer.interface.writeInt(u32, ZATEX_VERSION + 1, .little);
    try writer.flush();
    file.close(testing.io);

    const read_file = try tmp.dir.openFile(testing.io, "bad.ztex", .{});
    defer read_file.close(testing.io);

    try testing.expectError(error.UnsupportedVersion, Zatex.read(testing.allocator, testing.io, read_file));
}
