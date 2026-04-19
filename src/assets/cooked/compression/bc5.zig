const std = @import("std");

const compression = @import("compression.zig");
const bc4 = @import("bc4.zig");

/// Encode a two-channel (RG) image as BC5_UNORM.
/// `src` must be `width * height * 2` bytes (R, G interleaved).
/// `dst` must be `ceil(width/4) * ceil(height/4) * 16` bytes — each block is
/// two BC4 blocks back-to-back (first R, then G).
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    std.debug.assert(src.len == @as(usize, width) * @as(usize, height) * 2);
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 16);

    var rg_block: [32]u8 = undefined;
    var r_block: [16]u8 = undefined;
    var g_block: [16]u8 = undefined;

    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            compression.extractBlock4x4(
                src,
                width,
                height,
                2,
                @as(u32, @intCast(bx)) * 4,
                @as(u32, @intCast(by)) * 4,
                &rg_block,
            );
            for (0..16) |i| {
                r_block[i] = rg_block[i * 2 + 0];
                g_block[i] = rg_block[i * 2 + 1];
            }
            const r_encoded = bc4.encodeBlock(r_block);
            const g_encoded = bc4.encodeBlock(g_block);
            const dst_off = (by * blocks_x + bx) * 16;
            @memcpy(dst[dst_off..][0..8], &r_encoded);
            @memcpy(dst[dst_off + 8 ..][0..8], &g_encoded);
        }
    }
}

const testing = std.testing;

test "encode: output size matches ceil(w/4)*ceil(h/4)*16" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 5 * 3 * 2);
    defer alloc.free(src);
    @memset(src, 100);

    const blocks = 2 * 1;
    const dst = try alloc.alloc(u8, blocks * 16);
    defer alloc.free(dst);

    encode(src, 5, 3, dst);
    try testing.expectEqual(@as(usize, 32), dst.len);
}

test "encode: solid block has equal endpoints in both halves" {
    // 4x4 RG, all pixels = (77, 150)
    var src: [16 * 2]u8 = undefined;
    for (0..16) |i| {
        src[i * 2 + 0] = 77;
        src[i * 2 + 1] = 150;
    }

    var dst: [16]u8 = undefined;
    encode(&src, 4, 4, &dst);

    // R half (first 8 bytes): endpoints both 77, selectors zero.
    try testing.expectEqual(@as(u8, 77), dst[0]);
    try testing.expectEqual(@as(u8, 77), dst[1]);
    for (dst[2..8]) |b| try testing.expectEqual(@as(u8, 0), b);

    // G half (next 8): endpoints both 150, selectors zero.
    try testing.expectEqual(@as(u8, 150), dst[8]);
    try testing.expectEqual(@as(u8, 150), dst[9]);
    for (dst[10..16]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "encode: R and G channels are encoded independently" {
    // R varies 0..255 across 16 texels; G is constant 128.
    var src: [16 * 2]u8 = undefined;
    for (0..16) |i| {
        src[i * 2 + 0] = @intCast(i * 17);
        src[i * 2 + 1] = 128;
    }

    var dst: [16]u8 = undefined;
    encode(&src, 4, 4, &dst);

    // R half: endpoints should be 255 (max) and 0 (min).
    try testing.expectEqual(@as(u8, 255), dst[0]);
    try testing.expectEqual(@as(u8, 0), dst[1]);

    // G half: endpoints both 128 (solid), selectors zero.
    try testing.expectEqual(@as(u8, 128), dst[8]);
    try testing.expectEqual(@as(u8, 128), dst[9]);
    for (dst[10..16]) |b| try testing.expectEqual(@as(u8, 0), b);
}
