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

pub fn encodeChannels(source: compression.ChannelView, dst: []u8) void {
    std.debug.assert(source.channel_count == 2);
    const blocks_x = (source.width + 3) / 4;
    const blocks_y = (source.height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 16);

    var r_block: [16]u8 = undefined;
    var g_block: [16]u8 = undefined;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            const origin_x = @as(u32, @intCast(bx)) * 4;
            const origin_y = @as(u32, @intCast(by)) * 4;
            extractChannelBlock(source, origin_x, origin_y, source.channels[0], &r_block);
            extractChannelBlock(source, origin_x, origin_y, source.channels[1], &g_block);
            const r_encoded = bc4.encodeBlock(r_block);
            const g_encoded = bc4.encodeBlock(g_block);
            const dst_off = (by * blocks_x + bx) * 16;
            @memcpy(dst[dst_off..][0..8], &r_encoded);
            @memcpy(dst[dst_off + 8 ..][0..8], &g_encoded);
        }
    }
}

fn extractChannelBlock(source: compression.ChannelView, origin_x: u32, origin_y: u32, channel: u32, dst: *[16]u8) void {
    std.debug.assert(channel < source.pixel_stride);
    for (0..4) |ly| {
        const y = @min(origin_y + @as(u32, @intCast(ly)), source.height - 1);
        for (0..4) |lx| {
            const x = @min(origin_x + @as(u32, @intCast(lx)), source.width - 1);
            const offset = @as(usize, y) * source.row_stride + @as(usize, x) * source.pixel_stride + channel;
            dst[ly * 4 + lx] = source.bytes[offset];
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

test "encodeChannels matches compact RG input" {
    var rgba: [5 * 3 * 4]u8 = undefined;
    var compact: [5 * 3 * 2]u8 = undefined;
    for (0..(5 * 3)) |i| {
        compact[i * 2 + 0] = @intCast(i * 11);
        compact[i * 2 + 1] = @intCast(255 - i * 9);
        rgba[i * 4 + 0] = compact[i * 2 + 0];
        rgba[i * 4 + 1] = compact[i * 2 + 1];
        rgba[i * 4 + 2] = 2;
        rgba[i * 4 + 3] = 3;
    }
    var expected: [32]u8 = undefined;
    var actual: [32]u8 = undefined;
    encode(&compact, 5, 3, &expected);
    encodeChannels(.{
        .bytes = &rgba,
        .width = 5,
        .height = 3,
        .row_stride = 5 * 4,
        .pixel_stride = 4,
        .channels = .{ 0, 1 },
        .channel_count = 2,
    }, &actual);
    try testing.expectEqualSlices(u8, &expected, &actual);
}
