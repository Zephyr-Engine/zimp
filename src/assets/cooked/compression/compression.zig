const std = @import("std");

const TexelFormat = @import("../texture.zig").TexelFormat;

pub const bc4 = @import("bc4.zig");
pub const bc5 = @import("bc5.zig");
pub const bc7 = @import("bc7.zig");
pub const bc6h = @import("bc6h.zig");

/// Encode a mip into its block-compressed on-disk representation.
///
/// `src` layout depends on `format`:
///   - .bc4:  width*height  bytes (single channel)
///   - .bc5:  width*height*2 bytes (RG interleaved)
///   - .bc7:  width*height*4 bytes (RGBA8)
///   - .bc6h: width*height*6 bytes (RGB f16 little-endian, same as rgb16f)
///
/// `dst.len` must equal `format.imageSize(width, height)`.
pub fn encode(
    format: TexelFormat,
    src: []const u8,
    width: u32,
    height: u32,
    dst: []u8,
) void {
    std.debug.assert(dst.len == format.imageSize(width, height));
    switch (format) {
        .bc4 => bc4.encode(src, width, height, dst),
        .bc5 => bc5.encode(src, width, height, dst),
        .bc7 => bc7.encode(src, width, height, dst),
        .bc6h => bc6h.encode(src, width, height, dst),
        else => unreachable,
    }
}

/// Read a 4x4 block of `bytes_per_pixel`-sized texels into `dst`, replicating
/// edge pixels when the block straddles the image boundary. Required for mips
/// whose dimensions aren't a multiple of 4 — notably the 1x1, 2x2, 1x2 tail.
pub fn extractBlock4x4(
    src: []const u8,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    block_x: u32,
    block_y: u32,
    dst: []u8,
) void {
    std.debug.assert(dst.len == 16 * bytes_per_pixel);
    const row_stride = @as(usize, width) * bytes_per_pixel;
    for (0..4) |ly| {
        const src_y = @min(block_y + @as(u32, @intCast(ly)), height - 1);
        for (0..4) |lx| {
            const src_x = @min(block_x + @as(u32, @intCast(lx)), width - 1);
            const src_off = @as(usize, src_y) * row_stride + @as(usize, src_x) * bytes_per_pixel;
            const dst_off = (ly * 4 + lx) * bytes_per_pixel;
            @memcpy(dst[dst_off..][0..bytes_per_pixel], src[src_off..][0..bytes_per_pixel]);
        }
    }
}

const testing = std.testing;

test "extractBlock4x4: full in-bounds block copies unchanged" {
    // 4x4 single-channel: fill with column index so we can verify layout.
    var src: [16]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        src[y * 4 + x] = @intCast(x);
    };

    var dst: [16]u8 = undefined;
    extractBlock4x4(&src, 4, 4, 1, 0, 0, &dst);

    try testing.expectEqualSlices(u8, &src, &dst);
}

test "extractBlock4x4: replicates edge when block overhangs" {
    // 2x2 image, single channel:  (0,0)=10 (1,0)=20 (0,1)=30 (1,1)=40
    const src = [_]u8{ 10, 20, 30, 40 };

    var dst: [16]u8 = undefined;
    extractBlock4x4(&src, 2, 2, 1, 0, 0, &dst);

    // Row 0: 10, 20, 20, 20   (x >= 1 clamps to x=1)
    // Row 1: 30, 40, 40, 40
    // Row 2: same as row 1 (y clamps to y=1)
    // Row 3: same as row 1
    const expected = [_]u8{
        10, 20, 20, 20,
        30, 40, 40, 40,
        30, 40, 40, 40,
        30, 40, 40, 40,
    };
    try testing.expectEqualSlices(u8, &expected, &dst);
}

test "extractBlock4x4: multi-byte pixels stay packed" {
    // 1x1 image, 2 bytes per pixel — every slot should be the same pair.
    const src = [_]u8{ 0xAA, 0xBB };
    var dst: [32]u8 = undefined;
    extractBlock4x4(&src, 1, 1, 2, 0, 0, &dst);

    for (0..16) |i| {
        try testing.expectEqual(@as(u8, 0xAA), dst[i * 2]);
        try testing.expectEqual(@as(u8, 0xBB), dst[i * 2 + 1]);
    }
}
