const std = @import("std");

const compression = @import("compression.zig");

/// Encode a single-channel image as BC4_UNORM.
/// `src` must be `width * height` bytes. `dst` must be
/// `ceil(width/4) * ceil(height/4) * 8` bytes.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    std.debug.assert(src.len == @as(usize, width) * @as(usize, height));
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 8);

    var block: [16]u8 = undefined;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            compression.extractBlock4x4(
                src,
                width,
                height,
                1,
                @as(u32, @intCast(bx)) * 4,
                @as(u32, @intCast(by)) * 4,
                &block,
            );
            const encoded = encodeBlock(block);
            const dst_off = (by * blocks_x + bx) * 8;
            @memcpy(dst[dst_off..][0..8], &encoded);
        }
    }
}

/// Encode a single 4x4 block of single-channel bytes as 8 BC4 output bytes.
///
/// Always emits 8-value mode (endpoints red0 = max, red1 = min). If max > min,
/// the palette interpolates seven values between them. If max == min, the block
/// is constant and all-zero indices decode to the same value.
pub fn encodeBlock(block: [16]u8) [8]u8 {
    var min_v: u8 = 255;
    var max_v: u8 = 0;
    for (block) |v| {
        if (v < min_v) {
            min_v = v;
        }

        if (v > max_v) {
            max_v = v;
        }
    }

    var out: [8]u8 = undefined;
    out[0] = max_v; // red0
    out[1] = min_v; // red1

    // 48-bit little-endian integer holding 16 × 3-bit indices.
    var indices: u64 = 0;

    if (max_v == min_v) {
        // Solid block: index 0 → palette[0] = red0 regardless of mode.
    } else {
        const palette = buildPalette8(max_v, min_v);
        for (block, 0..) |v, i| {
            const idx = closestIndex(palette, v);
            indices |= @as(u64, idx) << @intCast(i * 3);
        }
    }

    out[2] = @truncate(indices >> 0);
    out[3] = @truncate(indices >> 8);
    out[4] = @truncate(indices >> 16);
    out[5] = @truncate(indices >> 24);
    out[6] = @truncate(indices >> 32);
    out[7] = @truncate(indices >> 40);
    return out;
}

/// 8-value palette for BC4 (red0 > red1 case).
fn buildPalette8(red0: u8, red1: u8) [8]u8 {
    const r0: u32 = red0;
    const r1: u32 = red1;
    return .{
        @intCast(r0),
        @intCast(r1),
        @intCast((6 * r0 + 1 * r1) / 7),
        @intCast((5 * r0 + 2 * r1) / 7),
        @intCast((4 * r0 + 3 * r1) / 7),
        @intCast((3 * r0 + 4 * r1) / 7),
        @intCast((2 * r0 + 5 * r1) / 7),
        @intCast((1 * r0 + 6 * r1) / 7),
    };
}

fn closestIndex(palette: [8]u8, v: u8) u3 {
    var best_idx: u3 = 0;
    var best_err: u32 = std.math.maxInt(u32);
    for (palette, 0..) |p, i| {
        const diff: i32 = @as(i32, v) - @as(i32, p);
        const err: u32 = @intCast(diff * diff);
        if (err < best_err) {
            best_err = err;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}

/// Test-only reference decoder: unpacks one BC4 block back to 16 bytes.
/// Follows the Khronos spec mode selection (red0 > red1 → 8-value; else 6-value).
fn decodeBlock(bytes: [8]u8) [16]u8 {
    const red0 = bytes[0];
    const red1 = bytes[1];
    const r0: u32 = red0;
    const r1: u32 = red1;

    var palette: [8]u8 = undefined;
    if (red0 > red1) {
        palette = .{
            @intCast(r0),
            @intCast(r1),
            @intCast((6 * r0 + 1 * r1) / 7),
            @intCast((5 * r0 + 2 * r1) / 7),
            @intCast((4 * r0 + 3 * r1) / 7),
            @intCast((3 * r0 + 4 * r1) / 7),
            @intCast((2 * r0 + 5 * r1) / 7),
            @intCast((1 * r0 + 6 * r1) / 7),
        };
    } else {
        palette = .{
            @intCast(r0),
            @intCast(r1),
            @intCast((4 * r0 + 1 * r1) / 5),
            @intCast((3 * r0 + 2 * r1) / 5),
            @intCast((2 * r0 + 3 * r1) / 5),
            @intCast((1 * r0 + 4 * r1) / 5),
            0,
            255,
        };
    }

    var indices: u64 = 0;
    indices |= @as(u64, bytes[2]) << 0;
    indices |= @as(u64, bytes[3]) << 8;
    indices |= @as(u64, bytes[4]) << 16;
    indices |= @as(u64, bytes[5]) << 24;
    indices |= @as(u64, bytes[6]) << 32;
    indices |= @as(u64, bytes[7]) << 40;

    var out: [16]u8 = undefined;
    for (0..16) |i| {
        const idx: u3 = @intCast((indices >> @intCast(i * 3)) & 0x7);
        out[i] = palette[idx];
    }
    return out;
}

const testing = std.testing;

test "encodeBlock: solid block has equal endpoints and zero indices" {
    const block: [16]u8 = @splat(77);
    const out = encodeBlock(block);

    try testing.expectEqual(@as(u8, 77), out[0]);
    try testing.expectEqual(@as(u8, 77), out[1]);
    for (out[2..8]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "encodeBlock: endpoints are max and min of the block" {
    var block: [16]u8 = @splat(100);
    block[5] = 200;
    block[12] = 10;

    const out = encodeBlock(block);

    try testing.expectEqual(@as(u8, 200), out[0]); // red0 = max
    try testing.expectEqual(@as(u8, 10), out[1]); // red1 = min
}

test "encodeBlock: round-trip reproduces solid block exactly" {
    const block: [16]u8 = @splat(123);
    const encoded = encodeBlock(block);
    const decoded = decodeBlock(encoded);

    try testing.expectEqualSlices(u8, &block, &decoded);
}

test "encodeBlock: round-trip reproduces endpoints exactly" {
    var block: [16]u8 = @splat(128);
    block[0] = 0;
    block[15] = 255;
    const encoded = encodeBlock(block);
    const decoded = decodeBlock(encoded);

    // The texels matching the palette endpoints (0 and 255) round-trip perfectly.
    try testing.expectEqual(@as(u8, 0), decoded[0]);
    try testing.expectEqual(@as(u8, 255), decoded[15]);
}

test "encodeBlock: round-trip error on 0..15 ramp stays within BC4 quantization" {
    var block: [16]u8 = undefined;
    for (0..16) |i| block[i] = @intCast(i * 17); // 0, 17, 34, ..., 255

    const encoded = encodeBlock(block);
    const decoded = decodeBlock(encoded);

    // BC4 has 8 palette entries across [min, max]; max quantization error is
    // (max - min) / 14 ≈ 18 for a full 0..255 range. Assert worst-case error.
    var max_err: u32 = 0;
    for (block, decoded) |a, b| {
        const diff: i32 = @as(i32, a) - @as(i32, b);
        const err: u32 = @intCast(@abs(diff));
        if (err > max_err) max_err = err;
    }
    try testing.expect(max_err <= 19);
}

test "encode: output size matches ceil(w/4)*ceil(h/4)*8" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 5 * 3);
    defer alloc.free(src);
    @memset(src, 42);

    const blocks = 2 * 1; // ceil(5/4)*ceil(3/4)
    const dst = try alloc.alloc(u8, blocks * 8);
    defer alloc.free(dst);

    encode(src, 5, 3, dst);
    try testing.expectEqual(@as(usize, 16), dst.len);
}

test "encode: 1x1 mip produces a single block that round-trips the texel" {
    const src = [_]u8{200};
    var dst: [8]u8 = undefined;
    encode(&src, 1, 1, &dst);

    const decoded = decodeBlock(dst);
    // All 16 decoded texels correspond to the replicated 1x1 input.
    for (decoded) |d| try testing.expectEqual(@as(u8, 200), d);
}

test "encode: 4x4 in-bounds block matches encodeBlock directly" {
    var src: [16]u8 = undefined;
    for (0..16) |i| src[i] = @intCast(i * 16);

    var dst: [8]u8 = undefined;
    encode(&src, 4, 4, &dst);

    const expected = encodeBlock(src);
    try testing.expectEqualSlices(u8, &expected, &dst);
}
