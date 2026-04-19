const std = @import("std");

const compression = @import("compression.zig");

/// Encode an RGB f16 image as BC6H_UFLOAT using mode 3 only.
///
/// Mode 3 = single partition, 10-bit endpoints (no delta encoding), 4-bit
/// indices. It's the simplest valid BC6H mode. As with BC7 mode 6, more modes
/// can be added to the dispatcher later without changing the on-disk format.
///
/// `src` must be `width * height * 6` bytes (3 channels × f16 little-endian).
/// `dst` must be `ceil(width/4) * ceil(height/4) * 16` bytes.
///
/// Only the *unsigned* BC6H variant is produced. Negative half-float inputs
/// clamp to zero; values above the largest finite half clamp down.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    std.debug.assert(src.len == @as(usize, width) * @as(usize, height) * 6);
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 16);

    var block: [16 * 6]u8 = undefined;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            compression.extractBlock4x4(
                src,
                width,
                height,
                6,
                @as(u32, @intCast(bx)) * 4,
                @as(u32, @intCast(by)) * 4,
                &block,
            );
            const encoded = encodeBlockMode3(block);
            const dst_off = (by * blocks_x + bx) * 16;
            @memcpy(dst[dst_off..][0..16], &encoded);
        }
    }
}

/// 4-bit index weights, scaled by 64.
const weights4 = [16]u32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

/// Clamp a half-float bit pattern into the encodable unsigned range, then map
/// into BC6H's interpolation space. The decoded output goes through a
/// `(interp * 31) >> 6` finalization, so we pre-scale the target by 64/31 here.
fn halfToInterp(h: u16) u16 {
    if (h & 0x8000 != 0) return 0; // negative → 0 for unsigned BC6H
    const safe: u32 = @min(@as(u32, h), 0x7BFF); // clamp to largest finite half
    return @intCast((safe * 64 + 15) / 31);
}

/// Unquantize a 10-bit endpoint value to 16-bit interp space.
fn unquantizeU10(e: u32) u32 {
    if (e == 0) return 0;
    if (e >= 0x3FF) return 0xFFFF;
    return (e << 6) | (e >> 4);
}

/// Quantize a 16-bit interp value to 10 bits (round-to-nearest, clamped).
fn quantizeU10(y: u32) u32 {
    return @min((y + 32) >> 6, 0x3FF);
}

/// Encode a single 4×4 block of RGB f16 (96 bytes) as mode 3 (16 bytes).
pub fn encodeBlockMode3(block: [16 * 6]u8) [16]u8 {
    // 1) Convert each texel's 3 channels from f16 bits into interp space.
    var texels: [16][3]u32 = undefined;
    for (0..16) |i| {
        const r_bits = std.mem.readInt(u16, block[i * 6 + 0 ..][0..2], .little);
        const g_bits = std.mem.readInt(u16, block[i * 6 + 2 ..][0..2], .little);
        const b_bits = std.mem.readInt(u16, block[i * 6 + 4 ..][0..2], .little);
        texels[i] = .{ halfToInterp(r_bits), halfToInterp(g_bits), halfToInterp(b_bits) };
    }

    // 2) Bounding box per channel.
    var lo: [3]u32 = .{ 0xFFFF, 0xFFFF, 0xFFFF };
    var hi: [3]u32 = .{ 0, 0, 0 };
    for (texels) |t| {
        for (0..3) |c| {
            if (t[c] < lo[c]) lo[c] = t[c];
            if (t[c] > hi[c]) hi[c] = t[c];
        }
    }

    // 3) Quantize endpoints to 10 bits.
    var e0: [3]u32 = undefined;
    var e1: [3]u32 = undefined;
    for (0..3) |c| {
        e0[c] = quantizeU10(lo[c]);
        e1[c] = quantizeU10(hi[c]);
    }

    // 4) Build the 16-entry palette in interp space.
    var uq0: [3]u32 = undefined;
    var uq1: [3]u32 = undefined;
    for (0..3) |c| {
        uq0[c] = unquantizeU10(e0[c]);
        uq1[c] = unquantizeU10(e1[c]);
    }
    var palette: [16][3]u32 = undefined;
    for (0..16) |k| {
        const w = weights4[k];
        for (0..3) |c| {
            palette[k][c] = ((64 - w) * uq0[c] + w * uq1[c] + 32) >> 6;
        }
    }

    // 5) Pick closest palette entry for each texel.
    var indices: [16]u4 = undefined;
    for (0..16) |i| {
        indices[i] = closestPaletteIndex(palette, texels[i]);
    }

    // 6) Anchor constraint: texel 0's index must fit in 3 bits.
    const swap = indices[0] >= 8;
    if (swap) {
        for (0..16) |i| indices[i] = @intCast(15 - @as(u32, indices[i]));
    }

    // 7) Pack 128 bits. Field order per Khronos/DirectX BC6H mode-3 spec:
    //    mode(5) | rw(10) | gw(10) | bw(10) | rx(10) | gx(10) | bx(10) | indices(63)
    //    where (rw,gw,bw) = endpoint 0 and (rx,gx,bx) = endpoint 1.
    var out: [16]u8 = @splat(0);
    var bit: u32 = 0;

    writeBits(&out, &bit, 0x03, 5); // mode 3: bits 00011 (LSB-first)

    const p0 = if (swap) e1 else e0;
    const p1 = if (swap) e0 else e1;

    writeBits(&out, &bit, p0[0], 10); // R0
    writeBits(&out, &bit, p0[1], 10); // G0
    writeBits(&out, &bit, p0[2], 10); // B0
    writeBits(&out, &bit, p1[0], 10); // R1
    writeBits(&out, &bit, p1[1], 10); // G1
    writeBits(&out, &bit, p1[2], 10); // B1

    // Indices: texel 0 = 3 bits (anchor), remaining 15 = 4 bits each.
    writeBits(&out, &bit, indices[0], 3);
    for (1..16) |i| writeBits(&out, &bit, indices[i], 4);

    std.debug.assert(bit == 128);
    return out;
}

fn closestPaletteIndex(palette: [16][3]u32, texel: [3]u32) u4 {
    var best: u4 = 0;
    var best_err: u64 = std.math.maxInt(u64);
    for (palette, 0..) |p, i| {
        var err: u64 = 0;
        for (0..3) |c| {
            const diff: i64 = @as(i64, texel[c]) - @as(i64, p[c]);
            err += @intCast(diff * diff);
        }
        if (err < best_err) {
            best_err = err;
            best = @intCast(i);
        }
    }
    return best;
}

fn writeBits(buf: []u8, bit: *u32, value: u32, num_bits: u32) void {
    std.debug.assert(num_bits <= 32);
    var v = value;
    var remaining = num_bits;
    while (remaining > 0) {
        const byte_idx: u32 = bit.* / 8;
        const bit_in_byte: u3 = @intCast(bit.* % 8);
        const space_in_byte: u32 = 8 - @as(u32, bit_in_byte);
        const take: u32 = @min(remaining, space_in_byte);
        const mask: u32 = (@as(u32, 1) << @intCast(take)) - 1;
        const chunk: u8 = @intCast(v & mask);
        buf[byte_idx] |= chunk << bit_in_byte;
        v >>= @intCast(take);
        bit.* += take;
        remaining -= take;
    }
}

const testing = std.testing;

test "halfToInterp: zero maps to zero" {
    try testing.expectEqual(@as(u16, 0), halfToInterp(0));
}

test "halfToInterp: negative half clamps to zero" {
    try testing.expectEqual(@as(u16, 0), halfToInterp(0x8001));
    try testing.expectEqual(@as(u16, 0), halfToInterp(0xBC00)); // -1.0
}

test "halfToInterp: max finite half maps below u16 ceiling" {
    const y = halfToInterp(0x7BFF);
    // (0x7BFF * 64 + 15) / 31 = (31743 * 64 + 15) / 31 = 65534
    try testing.expectEqual(@as(u16, 65534), y);
}

test "quantizeU10: round trip through unquantize stays close" {
    // Exercise a range of values; after quantize+unquantize we should be within
    // the 6-bit quantization step.
    var y: u32 = 0;
    while (y < 0xFFFF) : (y += 521) {
        const q = quantizeU10(y);
        const u = unquantizeU10(q);
        const diff: i32 = @as(i32, @intCast(y)) - @as(i32, @intCast(u));
        try testing.expect(@abs(diff) < 128);
    }
}

test "encodeBlockMode3: output begins with mode 3 bit pattern" {
    const block: [96]u8 = @splat(0);
    const out = encodeBlockMode3(block);
    // Mode 3 = 5 bits of value 3 = 00011 (LSB-first). Bottom 5 bits of byte 0 = 0x03.
    try testing.expectEqual(@as(u8, 0x03), out[0] & 0x1F);
}

test "encodeBlockMode3: exactly 128 bits are packed" {
    // encodeBlockMode3 internally asserts bit == 128.
    const block: [96]u8 = @splat(0);
    _ = encodeBlockMode3(block);
}

test "encodeBlockMode3: all-zero input encodes cleanly" {
    const block: [96]u8 = @splat(0);
    const out = encodeBlockMode3(block);
    // All endpoints quantize to 0, palette entries all 0, indices all 0 → we
    // only have the 5 mode bits set.
    try testing.expectEqual(@as(u8, 0x03), out[0]);
    for (out[1..16]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "encode: output size matches ceil(w/4)*ceil(h/4)*16" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 5 * 3 * 6);
    defer alloc.free(src);
    @memset(src, 0);

    const blocks = 2 * 1;
    const dst = try alloc.alloc(u8, blocks * 16);
    defer alloc.free(dst);

    encode(src, 5, 3, dst);
    try testing.expectEqual(@as(usize, 32), dst.len);
}
