const std = @import("std");

const raw_texture = @import("../raw/texture.zig");
const RawTexture = raw_texture.RawTexture;
const TextureClass = raw_texture.TextureClass;
const ColorSpace = raw_texture.ColorSpace;
const compression = @import("compression/compression.zig");

/// Target texel format for a cooked mip level. Values match the on-disk ZTex
/// format enum so they can be written directly.
pub const TexelFormat = enum(u16) {
    rgba8 = 0,
    rg8 = 1,
    r8 = 2,
    rgb16f = 3,
    bc4 = 10,
    bc5 = 11,
    bc7 = 12,
    bc6h = 13,

    pub fn isBlockCompressed(self: TexelFormat) bool {
        return switch (self) {
            .rgba8, .rg8, .r8, .rgb16f => false,
            .bc4, .bc5, .bc7, .bc6h => true,
        };
    }

    pub fn blockWidth(self: TexelFormat) u32 {
        return if (self.isBlockCompressed()) 4 else 1;
    }

    pub fn blockHeight(self: TexelFormat) u32 {
        return if (self.isBlockCompressed()) 4 else 1;
    }

    /// Bytes per block. For non-compressed formats, a "block" is a single texel.
    pub fn bytesPerBlock(self: TexelFormat) usize {
        return switch (self) {
            .rgba8 => 4,
            .rg8 => 2,
            .r8 => 1,
            .rgb16f => 6,
            .bc4 => 8,
            .bc5, .bc7, .bc6h => 16,
        };
    }

    /// Size in bytes of a mip of the given logical dimensions.
    /// For block-compressed formats, dimensions are rounded up to the block grid.
    pub fn imageSize(self: TexelFormat, width: u32, height: u32) usize {
        const bw = self.blockWidth();
        const bh = self.blockHeight();
        const blocks_x = (width + bw - 1) / bw;
        const blocks_y = (height + bh - 1) / bh;
        return @as(usize, blocks_x) * @as(usize, blocks_y) * self.bytesPerBlock();
    }
};

pub const CookedMip = struct {
    width: u32,
    height: u32,
    data: []u8,
};

pub const CookedTexture = struct {
    width: u32,
    height: u32,
    format: TexelFormat,
    color_space: ColorSpace,
    mips: []CookedMip,

    pub fn deinit(self: *CookedTexture, allocator: std.mem.Allocator) void {
        for (self.mips) |mip| allocator.free(mip.data);
        allocator.free(self.mips);
    }

    pub fn cook(allocator: std.mem.Allocator, raw: *const RawTexture) !CookedTexture {
        const format = selectFormat(raw.class);

        const raw_mips = try raw.generateMipmaps(allocator);
        defer {
            for (raw_mips) |mip| mip.deinit(allocator);
            allocator.free(raw_mips);
        }

        const mips = try allocator.alloc(CookedMip, raw_mips.len);
        errdefer allocator.free(mips);

        var cooked_count: usize = 0;
        errdefer for (mips[0..cooked_count]) |mip| allocator.free(mip.data);

        for (raw_mips, mips) |*src, *dst| {
            dst.* = try cookMip(allocator, src, format);
            cooked_count += 1;
        }

        return .{
            .width = raw.width,
            .height = raw.height,
            .format = format,
            .color_space = raw.class.colorSpace(),
            .mips = mips,
        };
    }
};

fn selectFormat(class: TextureClass) TexelFormat {
    return switch (class) {
        .color_srgb => .bc7,
        .normal_linear => .bc5,
        .single_linear => .bc4,
        .packed_linear => .bc7,
        .hdr_linear => .bc6h,
    };
}

/// Extracts the channels the target format expects from a source mip.
/// LDR formats (rgba8/rg8/r8) read from `src.pixels.ldr`; rgb16f reads from `src.pixels.hdr`.
/// Block compression of the resulting bytes is still a TODO.
fn cookMip(allocator: std.mem.Allocator, src: *const RawTexture, format: TexelFormat) !CookedMip {
    const pixel_count = @as(usize, src.width) * @as(usize, src.height);
    const data = try allocator.alloc(u8, format.imageSize(src.width, src.height));
    errdefer allocator.free(data);

    switch (format) {
        .rgba8 => @memcpy(data, src.pixels.ldr),
        .rg8 => {
            const ldr = src.pixels.ldr;
            for (0..pixel_count) |i| {
                data[i * 2 + 0] = ldr[i * 4 + 0];
                data[i * 2 + 1] = ldr[i * 4 + 1];
            }
        },
        .r8 => {
            const ldr = src.pixels.ldr;
            for (0..pixel_count) |i| {
                data[i] = ldr[i * 4];
            }
        },
        .rgb16f => {
            const hdr = src.pixels.hdr;
            for (0..pixel_count) |i| {
                const r: f16 = @floatCast(hdr[i * 3 + 0]);
                const g: f16 = @floatCast(hdr[i * 3 + 1]);
                const b: f16 = @floatCast(hdr[i * 3 + 2]);
                std.mem.writeInt(u16, data[i * 6 + 0 ..][0..2], @bitCast(r), .little);
                std.mem.writeInt(u16, data[i * 6 + 2 ..][0..2], @bitCast(g), .little);
                std.mem.writeInt(u16, data[i * 6 + 4 ..][0..2], @bitCast(b), .little);
            }
        },
        .bc4 => {
            const ldr = src.pixels.ldr;
            const r_channel = try allocator.alloc(u8, pixel_count);
            defer allocator.free(r_channel);
            for (0..pixel_count) |i| r_channel[i] = ldr[i * 4];
            compression.encode(.bc4, r_channel, src.width, src.height, data);
        },
        .bc5 => {
            const ldr = src.pixels.ldr;
            const rg = try allocator.alloc(u8, pixel_count * 2);
            defer allocator.free(rg);
            for (0..pixel_count) |i| {
                rg[i * 2 + 0] = ldr[i * 4 + 0];
                rg[i * 2 + 1] = ldr[i * 4 + 1];
            }
            compression.encode(.bc5, rg, src.width, src.height, data);
        },
        .bc7 => {
            // Source is already the RGBA8 layout stb_image produced.
            compression.encode(.bc7, src.pixels.ldr, src.width, src.height, data);
        },
        .bc6h => {
            const hdr = src.pixels.hdr;
            const rgb_half = try allocator.alloc(u8, pixel_count * 6);
            defer allocator.free(rgb_half);
            for (0..pixel_count) |i| {
                const r: f16 = @floatCast(hdr[i * 3 + 0]);
                const g: f16 = @floatCast(hdr[i * 3 + 1]);
                const b: f16 = @floatCast(hdr[i * 3 + 2]);
                std.mem.writeInt(u16, rgb_half[i * 6 + 0 ..][0..2], @bitCast(r), .little);
                std.mem.writeInt(u16, rgb_half[i * 6 + 2 ..][0..2], @bitCast(g), .little);
                std.mem.writeInt(u16, rgb_half[i * 6 + 4 ..][0..2], @bitCast(b), .little);
            }
            compression.encode(.bc6h, rgb_half, src.width, src.height, data);
        },
    }

    return .{ .width = src.width, .height = src.height, .data = data };
}

const testing = std.testing;

fn makeUniformRaw(allocator: std.mem.Allocator, width: u32, height: u32, class: TextureClass, fill: u8) !RawTexture {
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    @memset(pixels, fill);
    return .{
        .width = width,
        .height = height,
        .channels = 4,
        .pixels = .{ .ldr = pixels },
        .class = class,
    };
}

fn makeUniformRawHdr(allocator: std.mem.Allocator, width: u32, height: u32, fill: [3]f32) !RawTexture {
    const pixel_count = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(f32, pixel_count * 3);
    for (0..pixel_count) |i| {
        pixels[i * 3 + 0] = fill[0];
        pixels[i * 3 + 1] = fill[1];
        pixels[i * 3 + 2] = fill[2];
    }
    return .{
        .width = width,
        .height = height,
        .channels = 3,
        .pixels = .{ .hdr = pixels },
        .class = .hdr_linear,
    };
}

test "selectFormat: color_srgb picks bc7" {
    try testing.expectEqual(TexelFormat.bc7, selectFormat(.color_srgb));
}

test "selectFormat: normal_linear picks bc5" {
    try testing.expectEqual(TexelFormat.bc5, selectFormat(.normal_linear));
}

test "selectFormat: single_linear picks bc4" {
    try testing.expectEqual(TexelFormat.bc4, selectFormat(.single_linear));
}

test "selectFormat: packed_linear picks bc7" {
    try testing.expectEqual(TexelFormat.bc7, selectFormat(.packed_linear));
}

test "selectFormat: hdr_linear picks bc6h" {
    try testing.expectEqual(TexelFormat.bc6h, selectFormat(.hdr_linear));
}

test "imageSize: rgba8 4x4 = 64" {
    try testing.expectEqual(@as(usize, 64), TexelFormat.rgba8.imageSize(4, 4));
}

test "imageSize: rg8 2x2 = 8" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.rg8.imageSize(2, 2));
}

test "imageSize: r8 3x5 = 15" {
    try testing.expectEqual(@as(usize, 15), TexelFormat.r8.imageSize(3, 5));
}

test "imageSize: bc4 4x4 = 8 (one block)" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc4.imageSize(4, 4));
}

test "imageSize: bc4 rounds sub-block dims up to a full block" {
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc4.imageSize(1, 1));
    try testing.expectEqual(@as(usize, 8), TexelFormat.bc4.imageSize(3, 3));
    try testing.expectEqual(@as(usize, 16), TexelFormat.bc4.imageSize(5, 3));
}

test "imageSize: bc7 8x8 = 64 (four 16-byte blocks)" {
    try testing.expectEqual(@as(usize, 64), TexelFormat.bc7.imageSize(8, 8));
}

test "isBlockCompressed" {
    try testing.expect(!TexelFormat.rgba8.isBlockCompressed());
    try testing.expect(TexelFormat.bc4.isBlockCompressed());
    try testing.expect(TexelFormat.bc7.isBlockCompressed());
}

test "cookMip: rgba8 preserves all channels" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };

    const mip = try cookMip(alloc, &src, .rgba8);
    defer alloc.free(mip.data);

    try testing.expectEqualSlices(u8, &pixels, mip.data);
}

test "cookMip: rg8 extracts R and G" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 100, 200, 255, 255, 50, 150, 255, 255 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .normal_linear };

    const mip = try cookMip(alloc, &src, .rg8);
    defer alloc.free(mip.data);

    try testing.expectEqualSlices(u8, &.{ 100, 200, 50, 150 }, mip.data);
}

test "cookMip: r8 extracts red only" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 77, 0, 0, 255, 88, 0, 0, 255 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .single_linear };

    const mip = try cookMip(alloc, &src, .r8);
    defer alloc.free(mip.data);

    try testing.expectEqualSlices(u8, &.{ 77, 88 }, mip.data);
}

test "cookMip: rgb16f converts f32 to little-endian f16" {
    const alloc = testing.allocator;
    var pixels = [_]f32{ 1.0, 2.0, 4.0, 0.5, 0.25, 0.125 };
    const src = RawTexture{ .width = 2, .height = 1, .channels = 3, .pixels = .{ .hdr = &pixels }, .class = .hdr_linear };

    const mip = try cookMip(alloc, &src, .rgb16f);
    defer alloc.free(mip.data);

    try testing.expectEqual(@as(usize, 2 * 6), mip.data.len);

    // Read back each f16 and confirm it matches the f32 input (within f16 precision).
    for (0..pixels.len) |i| {
        const bits = std.mem.readInt(u16, mip.data[i * 2 ..][0..2], .little);
        const half: f16 = @bitCast(bits);
        try testing.expectApproxEqAbs(pixels[i], @as(f32, half), 0.001);
    }
}

test "CookedTexture.cook: preserves dimensions and picks color_space" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 4, 4, .color_srgb, 128);
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw);
    defer cooked.deinit(alloc);

    try testing.expectEqual(@as(u32, 4), cooked.width);
    try testing.expectEqual(@as(u32, 4), cooked.height);
    try testing.expectEqual(ColorSpace.srgb, cooked.color_space);
    try testing.expectEqual(TexelFormat.bc7, cooked.format);
}

test "CookedTexture.cook: produces full mip chain" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 4, 4, .single_linear, 100);
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw);
    defer cooked.deinit(alloc);

    // log2(4) + 1 = 3 levels: 4x4, 2x2, 1x1
    try testing.expectEqual(@as(usize, 3), cooked.mips.len);
    try testing.expectEqual(@as(u32, 4), cooked.mips[0].width);
    try testing.expectEqual(@as(u32, 2), cooked.mips[1].width);
    try testing.expectEqual(@as(u32, 1), cooked.mips[2].width);
}

test "CookedTexture.cook: normal_linear produces bc5 mips" {
    const alloc = testing.allocator;
    // Pixel (128, 128, 255) → signed normal (0, 0, 1)
    const pixel_count: usize = 4 * 4;
    const pixels = try alloc.alloc(u8, pixel_count * 4);
    for (0..pixel_count) |i| {
        pixels[i * 4 + 0] = 128;
        pixels[i * 4 + 1] = 128;
        pixels[i * 4 + 2] = 255;
        pixels[i * 4 + 3] = 255;
    }
    var raw = RawTexture{ .width = 4, .height = 4, .channels = 4, .pixels = .{ .ldr = pixels }, .class = .normal_linear };
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw);
    defer cooked.deinit(alloc);

    try testing.expectEqual(TexelFormat.bc5, cooked.format);
    try testing.expectEqual(ColorSpace.linear, cooked.color_space);

    // Each mip is one BC5 block (2 × 8-byte BC4 halves = 16 bytes) since dims collapse to ≤4x4.
    for (cooked.mips) |mip| {
        try testing.expectEqual(@as(usize, 16), mip.data.len);
    }

    // On a uniform (128, 128) block, BC4 endpoints both equal 128 and selectors are all zero.
    const top = cooked.mips[0];
    try testing.expectEqual(@as(u8, 128), top.data[0]); // R red0
    try testing.expectEqual(@as(u8, 128), top.data[1]); // R red1
    try testing.expectEqual(@as(u8, 128), top.data[8]); // G red0
    try testing.expectEqual(@as(u8, 128), top.data[9]); // G red1
}

test "CookedTexture.cook: single_linear produces bc4 mips" {
    const alloc = testing.allocator;
    var raw = try makeUniformRaw(alloc, 4, 4, .single_linear, 77);
    defer raw.deinit(alloc);

    var cooked = try CookedTexture.cook(alloc, &raw);
    defer cooked.deinit(alloc);

    try testing.expectEqual(TexelFormat.bc4, cooked.format);
    // Each mip is one 4x4 block = 8 bytes (sub-4 mips round up).
    for (cooked.mips) |mip| {
        try testing.expectEqual(@as(usize, 8), mip.data.len);
        // Uniform input → endpoints equal the source value, selectors all zero.
        try testing.expectEqual(@as(u8, 77), mip.data[0]);
        try testing.expectEqual(@as(u8, 77), mip.data[1]);
        for (mip.data[2..8]) |b| try testing.expectEqual(@as(u8, 0), b);
    }
}
