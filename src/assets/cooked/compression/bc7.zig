const std = @import("std");

const compression = @import("compression.zig");

/// Encode an RGBA8 image as BC7_UNORM using mode 6 only.
///
/// Mode 6 = single partition, 4-bit indices, 7-bit endpoints + 1 p-bit per
/// endpoint. It's the simplest valid BC7 mode and compresses any RGBA block
/// without exploiting partitioning. Future quality upgrades can add more modes
/// to the dispatcher; the on-disk format doesn't change.
///
/// `src` must be `width * height * 4` bytes (RGBA8).
/// `dst` must be `ceil(width/4) * ceil(height/4) * 16` bytes.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    std.debug.assert(src.len == @as(usize, width) * @as(usize, height) * 4);
    const blocks_x = (width + 3) / 4;
    const blocks_y = (height + 3) / 4;
    std.debug.assert(dst.len == @as(usize, blocks_x) * @as(usize, blocks_y) * 16);

    var block: [64]u8 = undefined;
    for (0..blocks_y) |by| {
        for (0..blocks_x) |bx| {
            compression.extractBlock4x4(
                src,
                width,
                height,
                4,
                @as(u32, @intCast(bx)) * 4,
                @as(u32, @intCast(by)) * 4,
                &block,
            );
            const encoded = encodeBlockMode6(block);
            const dst_off = (by * blocks_x + bx) * 16;
            @memcpy(dst[dst_off..][0..16], &encoded);
        }
    }
}

/// BC7 mode 6 palette weights for 4-bit indices, scaled by 64.
const weights4 = compression.weights4;

/// Nearest BC7 weight for every integer projection in the [0, 64] weight
/// domain. Ties deliberately select the lower selector, matching the
/// exhaustive search's first-match behavior.
const nearest_weight_index: [65]u4 = blk: {
    @setEvalBranchQuota(2_000);
    var table: [65]u4 = undefined;
    for (0..65) |projected| {
        var best: u4 = 0;
        var best_distance: u32 = std.math.maxInt(u32);
        for (weights4, 0..) |weight, index| {
            const distance = @abs(@as(i32, @intCast(projected)) - @as(i32, @intCast(weight)));
            if (distance < best_distance) {
                best = @intCast(index);
                best_distance = @intCast(distance);
            }
        }
        table[projected] = best;
    }
    break :blk table;
};

const Endpoint = [4]u8;

/// Encode a single 4×4 RGBA block (64 bytes, row-major) as mode 6 (16 bytes).
pub fn encodeBlockMode6(block: [64]u8) [16]u8 {
    // 1) Bounding-box endpoints: per-channel min and max across the block.
    var ep0: Endpoint = .{ 255, 255, 255, 255 };
    var ep1: Endpoint = .{ 0, 0, 0, 0 };
    for (0..16) |i| {
        for (0..4) |c| {
            const v = block[i * 4 + c];
            if (v < ep0[c]) ep0[c] = v;
            if (v > ep1[c]) ep1[c] = v;
        }
    }

    // 2) Choose p-bits for each endpoint by trying both values and keeping the
    //    one with lower channel-quantization error.
    const q0 = quantizeEndpoint(ep0);
    const q1 = quantizeEndpoint(ep1);

    const final0 = expandEndpoint(q0);
    const final1 = expandEndpoint(q1);

    // 3) Build 16-entry palette interpolating between the two expanded endpoints.
    var palette: [16]Endpoint = undefined;
    for (0..16) |w| {
        const weight = weights4[w];
        for (0..4) |c| {
            const a: u32 = final0[c];
            const b: u32 = final1[c];
            palette[w][c] = @intCast(((64 - weight) * a + weight * b + 32) >> 6);
        }
    }

    // 4) For each texel, pick the closest palette entry (L2 in 4-channel space).
    var indices: [16]u4 = undefined;
    for (0..16) |i| {
        const texel: Endpoint = .{
            block[i * 4 + 0],
            block[i * 4 + 1],
            block[i * 4 + 2],
            block[i * 4 + 3],
        };
        indices[i] = closestPaletteIndex(palette, texel);
    }

    // 5) Anchor constraint: texel 0's index must have MSB = 0 (fit in 3 bits).
    //    If not, swap endpoints and invert all indices (new = 15 - old).
    const swap = indices[0] >= 8;
    if (swap) {
        for (0..16) |i| indices[i] = @intCast(15 - @as(u32, indices[i]));
    }

    // 6) Pack 128 bits.
    var out: [16]u8 = @splat(0);
    var bit: u32 = 0;

    // Mode bits: 7 bits, value = 0x40 (bit 6 set).
    compression.writeBits(&out, &bit, 0x40, 7);

    const e0 = if (swap) q1 else q0;
    const e1 = if (swap) q0 else q1;

    // Endpoint channels: 7 bits each, order R0 R1 G0 G1 B0 B1 A0 A1.
    compression.writeBits(&out, &bit, e0.channels[0], 7);
    compression.writeBits(&out, &bit, e1.channels[0], 7);
    compression.writeBits(&out, &bit, e0.channels[1], 7);
    compression.writeBits(&out, &bit, e1.channels[1], 7);
    compression.writeBits(&out, &bit, e0.channels[2], 7);
    compression.writeBits(&out, &bit, e1.channels[2], 7);
    compression.writeBits(&out, &bit, e0.channels[3], 7);
    compression.writeBits(&out, &bit, e1.channels[3], 7);

    // P-bits: P0 then P1 (one bit each).
    compression.writeBits(&out, &bit, e0.p_bit, 1);
    compression.writeBits(&out, &bit, e1.p_bit, 1);

    // Indices: texel 0 = 3 bits (anchor), remaining 15 texels = 4 bits each.
    compression.writeBits(&out, &bit, indices[0], 3);
    for (1..16) |i| compression.writeBits(&out, &bit, indices[i], 4);

    std.debug.assert(bit == 128);
    return out;
}

const QuantizedEndpoint = struct {
    channels: [4]u32, // each in [0, 127]
    p_bit: u32, // 0 or 1
};

/// Pick the p-bit (0 or 1) and 7-bit channel values that best approximate the
/// 8-bit endpoint. Error is measured as sum-of-squared channel deltas after
/// expanding back through expandEndpoint.
fn quantizeEndpoint(ep: Endpoint) QuantizedEndpoint {
    var best: QuantizedEndpoint = undefined;
    var best_err: u32 = std.math.maxInt(u32);

    for (0..2) |p_usize| {
        const p: u32 = @intCast(p_usize);
        var candidate: QuantizedEndpoint = .{ .channels = undefined, .p_bit = p };
        var err: u32 = 0;
        for (0..4) |c| {
            const x: i32 = ep[c];
            // Optimal 7-bit value: round((x - p) / 2), clamped to [0, 127].
            var v: i32 = @divFloor(x - @as(i32, @intCast(p)) + 1, 2);
            if (v < 0) v = 0;
            if (v > 127) v = 127;
            candidate.channels[c] = @intCast(v);

            const restored: i32 = (v * 2) | @as(i32, @intCast(p));
            const diff = x - restored;
            err += @intCast(diff * diff);
        }
        if (err < best_err) {
            best_err = err;
            best = candidate;
        }
    }
    return best;
}

fn expandEndpoint(q: QuantizedEndpoint) Endpoint {
    return .{
        @intCast((q.channels[0] << 1) | q.p_bit),
        @intCast((q.channels[1] << 1) | q.p_bit),
        @intCast((q.channels[2] << 1) | q.p_bit),
        @intCast((q.channels[3] << 1) | q.p_bit),
    };
}

fn closestPaletteIndex(palette: [16]Endpoint, texel: Endpoint) u4 {
    const first = palette[0];
    const last = palette[15];
    var numerator: i32 = 0;
    var denominator: u32 = 0;
    for (0..4) |channel| {
        const direction = @as(i32, last[channel]) - @as(i32, first[channel]);
        numerator += (@as(i32, texel[channel]) - @as(i32, first[channel])) * direction;
        denominator += @intCast(direction * direction);
    }

    // A constant palette always selects zero. This is common for flat-color
    // blocks and avoids both division and selector-distance calculations.
    if (denominator == 0) return 0;

    const projected: u32 = @intCast(std.math.clamp(
        @divTrunc(@as(i64, numerator) * 64 + @as(i64, denominator / 2), denominator),
        0,
        64,
    ));
    const center = nearest_weight_index[projected];
    const begin: u4 = center -| 2;
    const end: u5 = @min(@as(u5, center) + 2, 15);

    var best: u4 = 0;
    var best_err: u32 = std.math.maxInt(u32);
    var i: u5 = begin;
    while (i <= end) : (i += 1) {
        const p = palette[i];
        var err: u32 = 0;
        for (0..4) |c| {
            const diff: i32 = @as(i32, texel[c]) - @as(i32, p[c]);
            err += @intCast(diff * diff);
        }
        if (err < best_err) {
            best_err = err;
            best = @intCast(i);
        }
    }
    return best;
}

fn closestPaletteIndexReference(palette: [16]Endpoint, texel: Endpoint) u4 {
    var best: u4 = 0;
    var best_err: u32 = std.math.maxInt(u32);
    for (palette, 0..) |p, i| {
        var err: u32 = 0;
        for (0..4) |c| {
            const diff: i32 = @as(i32, texel[c]) - @as(i32, p[c]);
            err += @intCast(diff * diff);
        }
        if (err < best_err) {
            best_err = err;
            best = @intCast(i);
        }
    }
    return best;
}

/// Write `num_bits` of `value` into `buf` starting at bit `*bit`, LSB-first.
/// Advances `*bit` by `num_bits`.
const testing = std.testing;

test "writeBits: packs LSB-first" {
    var buf: [4]u8 = @splat(0);
    var bit: u32 = 0;
    compression.writeBits(&buf, &bit, 0b101, 3);
    compression.writeBits(&buf, &bit, 0b1111, 4);
    // Bits written LSB-first: 1,0,1,1,1,1,1 → byte 0 = 0b01111101 = 0x7D
    try testing.expectEqual(@as(u8, 0x7D), buf[0]);
    try testing.expectEqual(@as(u32, 7), bit);
}

test "writeBits: spans byte boundaries" {
    var buf: [4]u8 = @splat(0);
    var bit: u32 = 4;
    compression.writeBits(&buf, &bit, 0xFF, 8);
    // 8 ones starting at bit 4: low 4 bits of byte 0 = 0xF0, low 4 bits of byte 1 = 0x0F
    try testing.expectEqual(@as(u8, 0xF0), buf[0]);
    try testing.expectEqual(@as(u8, 0x0F), buf[1]);
    try testing.expectEqual(@as(u32, 12), bit);
}

test "encodeBlockMode6: output starts with mode 6 bit pattern" {
    const block: [64]u8 = @splat(128);
    const out = encodeBlockMode6(block);
    // Mode 6 bits: 0x40 (bit 6 set) in the low 7 bits of byte 0.
    try testing.expectEqual(@as(u8, 0x40), out[0] & 0x7F);
}

test "encodeBlockMode6: exactly 128 bits written" {
    // encodeBlockMode6 internally asserts bit == 128; this test is a sanity check.
    const block: [64]u8 = @splat(0);
    _ = encodeBlockMode6(block);
}

test "encode: output size matches ceil(w/4)*ceil(h/4)*16" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 5 * 3 * 4);
    defer alloc.free(src);
    @memset(src, 100);

    const blocks = 2 * 1;
    const dst = try alloc.alloc(u8, blocks * 16);
    defer alloc.free(dst);

    encode(src, 5, 3, dst);
    try testing.expectEqual(@as(usize, 32), dst.len);
}

test "encodeBlockMode6: solid block produces constant palette" {
    var block: [64]u8 = undefined;
    for (0..16) |i| {
        block[i * 4 + 0] = 200;
        block[i * 4 + 1] = 100;
        block[i * 4 + 2] = 50;
        block[i * 4 + 3] = 255;
    }
    const out = encodeBlockMode6(block);

    // No assertion on byte-exact output (we don't ship a reference decoder),
    // but the block should encode without panicking and begin with the mode 6 bit.
    try testing.expectEqual(@as(u8, 0x40), out[0] & 0x7F);
}

test "projected selector search matches exhaustive search" {
    var prng = std.Random.DefaultPrng.init(0x5a17_bcc7_2026);
    const random = prng.random();

    for (0..100_000) |_| {
        var low: Endpoint = undefined;
        var high: Endpoint = undefined;
        for (0..4) |channel| {
            const a = random.int(u8);
            const b = random.int(u8);
            low[channel] = @min(a, b);
            high[channel] = @max(a, b);
        }

        const q0 = quantizeEndpoint(low);
        const q1 = quantizeEndpoint(high);
        const final0 = expandEndpoint(q0);
        const final1 = expandEndpoint(q1);
        var palette: [16]Endpoint = undefined;
        for (weights4, 0..) |weight, index| {
            for (0..4) |channel| {
                palette[index][channel] = @intCast(((64 - weight) * @as(u32, final0[channel]) + weight * @as(u32, final1[channel]) + 32) >> 6);
            }
        }

        var texel: Endpoint = undefined;
        for (0..4) |channel| {
            const span = @as(u16, high[channel]) - low[channel] + 1;
            texel[channel] = low[channel] + @as(u8, @intCast(random.int(u16) % span));
        }
        try testing.expectEqual(closestPaletteIndexReference(palette, texel), closestPaletteIndex(palette, texel));
    }
}
