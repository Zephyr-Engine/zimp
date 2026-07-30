const std = @import("std");
const log = @import("../../logger.zig");

pub const stb = @cImport({
    @cInclude("stb_image.h");
});

pub const ColorSpace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const TextureClass = enum {
    color_srgb, // albedo, diffuse, color, basecolor, emissive
    normal_linear, // normal, nrm
    single_linear, // roughness, metallic, ao, height, opacity, displacement
    packed_linear, // orm, rm (multi-channel packed data)
    hdr_linear, // .hdr, .exr files

    const stem_map = std.StaticStringMap(TextureClass).initComptime(.{
        .{ "albedo", .color_srgb },
        .{ "diffuse", .color_srgb },
        .{ "color", .color_srgb },
        .{ "basecolor", .color_srgb },
        .{ "emissive", .color_srgb },
        .{ "emission", .color_srgb },
        .{ "normal", .normal_linear },
        .{ "nrm", .normal_linear },
        .{ "roughness", .single_linear },
        .{ "rough", .single_linear },
        .{ "metallic", .single_linear },
        .{ "metal", .single_linear },
        .{ "ao", .single_linear },
        .{ "occlusion", .single_linear },
        .{ "height", .single_linear },
        .{ "displacement", .single_linear },
        .{ "opacity", .single_linear },
        .{ "alpha", .single_linear },
        .{ "orm", .packed_linear },
        .{ "rm", .packed_linear },
    });

    const ext_map = std.StaticStringMap(TextureClass).initComptime(.{
        .{ ".hdr", .hdr_linear },
        .{ ".exr", .hdr_linear },
    });

    pub fn classify(file_name: []const u8) TextureClass {
        const ext = std.fs.path.extension(file_name);
        if (ext_map.get(ext)) |class| {
            return class;
        }

        const stem = blk: {
            const base = std.fs.path.stem(file_name);
            if (std.mem.lastIndexOfScalar(u8, base, '_')) |idx| {
                break :blk base[idx + 1 ..];
            }
            break :blk base;
        };

        if (stem_map.get(stem)) |class| {
            return class;
        }

        return .color_srgb;
    }

    const srgb_to_linear_lut: [256]f32 = blk: {
        var lut: [256]f32 = undefined;
        for (0..256) |i| {
            const f: f32 = @as(f32, @floatFromInt(i)) / 255.0;
            lut[i] = if (f > 0) @exp(@log(f) * 2.2) else 0.0;
        }
        break :blk lut;
    };

    pub fn decode(self: TextureClass, v: u8) f32 {
        return switch (self) {
            .color_srgb => srgb_to_linear_lut[v],
            .normal_linear => @as(f32, @floatFromInt(v)) / 255.0 * 2.0 - 1.0,
            else => @as(f32, @floatFromInt(v)) / 255.0,
        };
    }

    pub fn encode(self: TextureClass, v: f32) u8 {
        return switch (self) {
            .color_srgb => @intFromFloat(std.math.pow(f32, std.math.clamp(v, 0.0, 1.0), 1.0 / 2.2) * 255.0 + 0.5),
            .normal_linear => @intFromFloat(std.math.clamp((v + 1.0) * 0.5 * 255.0 + 0.5, 0.0, 255.0)),
            else => @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5),
        };
    }

    pub fn postAverage(self: TextureClass, r: f32, g: f32, b: f32) [3]f32 {
        if (self == .normal_linear) {
            const len = @sqrt(r * r + g * g + b * b);
            const s = if (len > 0.0) 1.0 / len else 0.0;
            return .{ r * s, g * s, b * s };
        }
        return .{ r, g, b };
    }

    pub fn colorSpace(self: TextureClass) ColorSpace {
        return switch (self) {
            .color_srgb => .srgb,
            else => .linear,
        };
    }
};

pub const Pixels = union(enum) {
    /// LDR: u8 per channel, layout depends on channel count (typically 4 for RGBA).
    ldr: []u8,
    /// HDR: linear f32 per channel, always 3 channels (RGB).
    hdr: []f32,
};

/// Identifies how `pixels` is released.
pub const PixelOwner = enum {
    borrowed,
    allocator,
    stb,
};

pub const RawTexture = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: Pixels,
    class: TextureClass,
    owner: PixelOwner = .borrowed,

    pub fn init(filename: []const u8, file_bytes: []u8) !RawTexture {
        const class = TextureClass.classify(filename);
        return if (class == .hdr_linear)
            initHdr(file_bytes, class)
        else
            initLdr(file_bytes, class);
    }

    fn initLdr(file_bytes: []u8, class: TextureClass) !RawTexture {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const stb_pixels = stb.stbi_load_from_memory(
            file_bytes.ptr,
            @intCast(file_bytes.len),
            &width,
            &height,
            &channels,
            4,
        );
        if (stb_pixels == null) return error.StbLoadFailed;

        const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        return RawTexture{
            .width = @as(u32, @intCast(width)),
            .height = @as(u32, @intCast(height)),
            .channels = 4,
            .pixels = .{ .ldr = stb_pixels[0..len] },
            .class = class,
            .owner = .stb,
        };
    }

    fn initHdr(file_bytes: []u8, class: TextureClass) !RawTexture {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const stb_pixels = stb.stbi_loadf_from_memory(
            file_bytes.ptr,
            @intCast(file_bytes.len),
            &width,
            &height,
            &channels,
            3,
        );
        if (stb_pixels == null) return error.StbLoadFailed;

        const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 3;
        return RawTexture{
            .width = @as(u32, @intCast(width)),
            .height = @as(u32, @intCast(height)),
            .channels = 3,
            .pixels = .{ .hdr = stb_pixels[0..len] },
            .class = class,
            .owner = .stb,
        };
    }

    pub fn deinit(self: *const RawTexture, allocator: std.mem.Allocator) void {
        switch (self.owner) {
            .borrowed => {},
            .allocator => switch (self.pixels) {
                .ldr => |p| allocator.free(p),
                .hdr => |p| allocator.free(p),
            },
            .stb => switch (self.pixels) {
                .ldr => |p| stb.stbi_image_free(@ptrCast(p.ptr)),
                .hdr => |p| stb.stbi_image_free(@ptrCast(p.ptr)),
            },
        }
    }

    /// LDR-only byte view of a pixel. Returns null if out of bounds.
    /// For HDR textures, access `self.pixels.hdr` directly.
    pub fn getPixel(self: *const RawTexture, x: u32, y: u32) ?[]const u8 {
        if (x >= self.width or y >= self.height) {
            return null;
        }

        return switch (self.pixels) {
            .ldr => |pixels| blk: {
                const idx = @as(usize, (y * self.width + x) * self.channels);
                break :blk pixels[idx .. idx + self.channels];
            },
            .hdr => null,
        };
    }

    /// LDR-only pixel write. Call only on textures with `pixels == .ldr`.
    pub fn setPixel(self: *RawTexture, x: u32, y: u32, color: []const u8) !void {
        if (x >= self.width or y >= self.height) {
            return error.OutOfBounds;
        }
        if (color.len != self.channels) {
            return error.InvalidColor;
        }

        const idx = @as(usize, (y * self.width + x) * self.channels);
        std.mem.copyForwards(u8, self.pixels.ldr[idx .. idx + self.channels], color);
    }

    pub fn mipScratchLen(self: *const RawTexture) usize {
        return @as(usize, @max(1, self.width / 2)) * @as(usize, self.height) * self.channels;
    }

    pub fn downsample(self: *const RawTexture, allocator: std.mem.Allocator, scratch: []f32) !RawTexture {
        var next = try allocateMip(allocator, self, @max(1, self.width / 2), @max(1, self.height / 2));
        errdefer next.deinit(allocator);
        switch (self.pixels) {
            .ldr => try kaiserFilter(self, &next, scratch),
            .hdr => try kaiserFilterHdr(self, &next, scratch),
        }
        return next;
    }

    /// Warns if any pixel in the normal map has a significantly non-unit normal.
    pub fn validateNormals(self: *const RawTexture) void {
        const tolerance = 0.1;
        var bad_count: u32 = 0;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                if (self.getPixel(@intCast(x), @intCast(y))) |color| {
                    const nx = self.class.decode(color[0]);
                    const ny = self.class.decode(color[1]);
                    const nz = self.class.decode(color[2]);
                    const len = @sqrt(nx * nx + ny * ny + nz * nz);
                    if (@abs(len - 1.0) > tolerance) {
                        bad_count += 1;
                    }
                }
            }
        }
        if (bad_count > 0) {
            log.warn("normal map has {d} pixels with non-unit normals out of {d} total", .{
                bad_count, self.width * self.height,
            });
        }
    }

    /// Separable Kaiser-windowed sinc filter for 2x downsampling of LDR data.
    /// Filters in linear space (class.decode → accumulate → class.encode),
    /// applies clamp-to-edge at borders.
    fn kaiserFilter(original_image: *const RawTexture, new_image: *RawTexture, scratch: []f32) !void {
        const class = original_image.class;
        const ch = original_image.channels;
        const scratch_len = @as(usize, new_image.width) * @as(usize, original_image.height) * ch;
        std.debug.assert(scratch.len >= scratch_len);

        // Horizontal pass: source -> scratch (new_width × original_height, linear f32)
        for (0..original_image.height) |y| {
            for (0..new_image.width) |x| {
                var c: [4]f32 = .{ 0, 0, 0, 0 };
                for (0..kaiser_taps) |i| {
                    const src_x_signed: i32 = @as(i32, @intCast(x)) * 2 + kaiser_start_offset + @as(i32, @intCast(i));
                    const src_x: u32 = @intCast(std.math.clamp(
                        src_x_signed,
                        0,
                        @as(i32, @intCast(original_image.width)) - 1,
                    ));
                    const color = original_image.getPixel(src_x, @intCast(y)).?;
                    const w = kaiser_weights[i];
                    c[0] += class.decode(color[0]) * w;
                    c[1] += class.decode(color[1]) * w;
                    c[2] += class.decode(color[2]) * w;
                    c[3] += @as(f32, @floatFromInt(color[3])) / 255.0 * w;
                }
                const idx = (y * new_image.width + x) * ch;
                scratch[idx + 0] = c[0];
                scratch[idx + 1] = c[1];
                scratch[idx + 2] = c[2];
                scratch[idx + 3] = c[3];
            }
        }

        // Vertical pass: scratch -> new_image (encode back to u8)
        for (0..new_image.height) |y| {
            for (0..new_image.width) |x| {
                var c: [4]f32 = .{ 0, 0, 0, 0 };
                for (0..kaiser_taps) |i| {
                    const src_y_signed: i32 = @as(i32, @intCast(y)) * 2 + kaiser_start_offset + @as(i32, @intCast(i));
                    const src_y: u32 = @intCast(std.math.clamp(
                        src_y_signed,
                        0,
                        @as(i32, @intCast(original_image.height)) - 1,
                    ));
                    const idx = (@as(usize, src_y) * new_image.width + x) * ch;
                    const w = kaiser_weights[i];
                    c[0] += scratch[idx + 0] * w;
                    c[1] += scratch[idx + 1] * w;
                    c[2] += scratch[idx + 2] * w;
                    c[3] += scratch[idx + 3] * w;
                }
                const rgb = class.postAverage(c[0], c[1], c[2]);
                const out_color = [4]u8{
                    class.encode(rgb[0]),
                    class.encode(rgb[1]),
                    class.encode(rgb[2]),
                    @intFromFloat(std.math.clamp(c[3], 0.0, 1.0) * 255.0 + 0.5),
                };
                try new_image.setPixel(@intCast(x), @intCast(y), &out_color);
            }
        }
    }

    /// Separable Kaiser-windowed sinc filter for 2x downsampling of HDR f32 data.
    /// No gamma conversion (already linear) and no normal-map normalization.
    fn kaiserFilterHdr(original_image: *const RawTexture, new_image: *RawTexture, scratch: []f32) !void {
        const ch = original_image.channels;
        const src = original_image.pixels.hdr;
        const dst = new_image.pixels.hdr;

        const scratch_len = @as(usize, new_image.width) * @as(usize, original_image.height) * ch;
        std.debug.assert(scratch.len >= scratch_len);

        // Horizontal pass
        for (0..original_image.height) |y| {
            for (0..new_image.width) |x| {
                var c: [4]f32 = .{ 0, 0, 0, 0 };
                for (0..kaiser_taps) |i| {
                    const src_x_signed: i32 = @as(i32, @intCast(x)) * 2 + kaiser_start_offset + @as(i32, @intCast(i));
                    const src_x: u32 = @intCast(std.math.clamp(
                        src_x_signed,
                        0,
                        @as(i32, @intCast(original_image.width)) - 1,
                    ));
                    const src_idx = (@as(usize, y) * original_image.width + src_x) * ch;
                    const w = kaiser_weights[i];
                    for (0..ch) |c_idx| c[c_idx] += src[src_idx + c_idx] * w;
                }
                const scratch_idx = (y * new_image.width + x) * ch;
                for (0..ch) |c_idx| scratch[scratch_idx + c_idx] = c[c_idx];
            }
        }

        // Vertical pass
        for (0..new_image.height) |y| {
            for (0..new_image.width) |x| {
                var c: [4]f32 = .{ 0, 0, 0, 0 };
                for (0..kaiser_taps) |i| {
                    const src_y_signed: i32 = @as(i32, @intCast(y)) * 2 + kaiser_start_offset + @as(i32, @intCast(i));
                    const src_y: u32 = @intCast(std.math.clamp(
                        src_y_signed,
                        0,
                        @as(i32, @intCast(original_image.height)) - 1,
                    ));
                    const scratch_idx = (@as(usize, src_y) * new_image.width + x) * ch;
                    const w = kaiser_weights[i];
                    for (0..ch) |c_idx| c[c_idx] += scratch[scratch_idx + c_idx] * w;
                }
                const dst_idx = (y * new_image.width + x) * ch;
                for (0..ch) |c_idx| dst[dst_idx + c_idx] = c[c_idx];
            }
        }
    }
};

fn allocateMip(
    allocator: std.mem.Allocator,
    source: *const RawTexture,
    width: u32,
    height: u32,
) !RawTexture {
    const sample_count = @as(usize, width) * @as(usize, height) * source.channels;
    return switch (source.pixels) {
        .ldr => .{
            .width = width,
            .height = height,
            .channels = source.channels,
            .pixels = .{ .ldr = try allocator.alloc(u8, sample_count) },
            .class = source.class,
            .owner = .allocator,
        },
        .hdr => .{
            .width = width,
            .height = height,
            .channels = source.channels,
            .pixels = .{ .hdr = try allocator.alloc(f32, sample_count) },
            .class = source.class,
            .owner = .allocator,
        },
    };
}

// Kaiser filter kernel parameters. Output pixel x's kernel center sits at source coord
// 2x + 1 (between two source pixels); offsets {-5..6} relative to 2x cover radius 3.
const kaiser_taps: usize = 12;
const kaiser_start_offset: i32 = -5;
const kaiser_radius: f32 = 3.0;
const kaiser_alpha: f32 = 4.0;
const kaiser_weights: [kaiser_taps]f32 = makeKaiserWeights();

fn makeKaiserWeights() [kaiser_taps]f32 {
    var weights: [kaiser_taps]f32 = undefined;
    computeKaiserWeights(&weights);
    return weights;
}

fn computeKaiserWeights(weights: *[kaiser_taps]f32) void {
    var weight_sum: f32 = 0;
    for (0..kaiser_taps) |i| {
        const offset_i: i32 = kaiser_start_offset + @as(i32, @intCast(i));
        const dist_out: f32 = (@as(f32, @floatFromInt(offset_i)) - 0.5) / 2.0;
        weights[i] = kaiserSinc(dist_out, kaiser_radius, kaiser_alpha);
        weight_sum += weights[i];
    }
    for (0..kaiser_taps) |i| weights[i] /= weight_sum;
}

fn kaiserSinc(x: f32, radius: f32, alpha: f32) f32 {
    const ax = @abs(x);
    if (ax >= radius) return 0;
    const sinc_val: f32 = if (ax < 1e-6) 1.0 else @sin(std.math.pi * x) / (std.math.pi * x);
    const t = ax / radius;
    const window = besselI0(alpha * @sqrt(1.0 - t * t)) / besselI0(alpha);
    return sinc_val * window;
}

/// Modified Bessel function of the first kind, order 0.
/// Series: I0(x) = Σ_{k=0}^∞ (x/2)^(2k) / (k!)^2
fn besselI0(x: f32) f32 {
    var result: f32 = 1.0;
    var term: f32 = 1.0;
    const half_x_sq = (x * 0.5) * (x * 0.5);
    var k: f32 = 1.0;
    var i: u32 = 1;
    while (i < 30) : (i += 1) {
        term *= half_x_sq / (k * k);
        result += term;
        if (term < 1e-7 * result) break;
        k += 1.0;
    }
    return result;
}

const testing = std.testing;

test "classify: albedo suffix maps to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("textures/brick_albedo.png"));
}

test "classify: diffuse suffix maps to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("brick_diffuse.jpg"));
}

test "classify: basecolor suffix maps to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("brick_basecolor.png"));
}

test "classify: emissive suffix maps to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("light_emissive.png"));
}

test "classify: emission suffix maps to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("light_emission.png"));
}

test "classify: normal suffix maps to normal_linear" {
    try testing.expectEqual(.normal_linear, TextureClass.classify("brick_normal.png"));
}

test "classify: nrm suffix maps to normal_linear" {
    try testing.expectEqual(.normal_linear, TextureClass.classify("brick_nrm.png"));
}

test "classify: roughness suffix maps to single_linear" {
    try testing.expectEqual(.single_linear, TextureClass.classify("brick_roughness.png"));
}

test "classify: metallic suffix maps to single_linear" {
    try testing.expectEqual(.single_linear, TextureClass.classify("metal_metallic.png"));
}

test "classify: ao suffix maps to single_linear" {
    try testing.expectEqual(.single_linear, TextureClass.classify("brick_ao.png"));
}

test "classify: height suffix maps to single_linear" {
    try testing.expectEqual(.single_linear, TextureClass.classify("terrain_height.png"));
}

test "classify: opacity suffix maps to single_linear" {
    try testing.expectEqual(.single_linear, TextureClass.classify("leaf_opacity.png"));
}

test "classify: alpha suffix maps to single_linear" {
    try testing.expectEqual(.single_linear, TextureClass.classify("leaf_alpha.png"));
}

test "classify: orm suffix maps to packed_linear" {
    try testing.expectEqual(.packed_linear, TextureClass.classify("brick_orm.png"));
}

test "classify: rm suffix maps to packed_linear" {
    try testing.expectEqual(.packed_linear, TextureClass.classify("brick_rm.png"));
}

test "classify: .hdr extension maps to hdr_linear" {
    try testing.expectEqual(.hdr_linear, TextureClass.classify("sky.hdr"));
}

test "classify: .exr extension maps to hdr_linear" {
    try testing.expectEqual(.hdr_linear, TextureClass.classify("sky.exr"));
}

test "classify: hdr extension takes priority over stem" {
    try testing.expectEqual(.hdr_linear, TextureClass.classify("sky_albedo.hdr"));
}

test "classify: unknown suffix defaults to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("photo.png"));
}

test "classify: no underscore in stem defaults to color_srgb" {
    try testing.expectEqual(.color_srgb, TextureClass.classify("texture.png"));
}

test "classify: nested path classifies correctly" {
    try testing.expectEqual(.normal_linear, TextureClass.classify("assets/textures/brick_normal.png"));
}

test "decode/encode round-trip: srgb 0 stays 0" {
    const v = TextureClass.color_srgb.decode(0);
    try testing.expectEqual(@as(u8, 0), TextureClass.color_srgb.encode(v));
}

test "decode/encode round-trip: srgb 255 stays 255" {
    const v = TextureClass.color_srgb.decode(255);
    try testing.expectEqual(@as(u8, 255), TextureClass.color_srgb.encode(v));
}

test "decode/encode round-trip: srgb 128 round-trips" {
    const v = TextureClass.color_srgb.decode(128);
    const result = TextureClass.color_srgb.encode(v);
    try testing.expectEqual(@as(u8, 128), result);
}

test "decode/encode round-trip: linear preserves value" {
    const class = TextureClass.single_linear;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        const decoded = class.decode(byte);
        const encoded = class.encode(decoded);
        try testing.expectEqual(byte, encoded);
    }
}

test "decode/encode round-trip: normal 128 maps to ~0 signed" {
    const class = TextureClass.normal_linear;
    const decoded = class.decode(128);
    try testing.expect(@abs(decoded) < 0.01);
}

test "decode/encode round-trip: normal 0 maps to -1" {
    const class = TextureClass.normal_linear;
    const decoded = class.decode(0);
    try testing.expect(@abs(decoded - (-1.0)) < 0.01);
}

test "decode/encode round-trip: normal 255 maps to 1" {
    const class = TextureClass.normal_linear;
    const decoded = class.decode(255);
    try testing.expect(@abs(decoded - 1.0) < 0.01);
}

test "postAverage: linear passes through unchanged" {
    const rgb = TextureClass.single_linear.postAverage(0.5, 0.3, 0.7);
    try testing.expectEqual(@as(f32, 0.5), rgb[0]);
    try testing.expectEqual(@as(f32, 0.3), rgb[1]);
    try testing.expectEqual(@as(f32, 0.7), rgb[2]);
}

test "postAverage: srgb passes through unchanged" {
    const rgb = TextureClass.color_srgb.postAverage(0.5, 0.3, 0.7);
    try testing.expectEqual(@as(f32, 0.5), rgb[0]);
    try testing.expectEqual(@as(f32, 0.3), rgb[1]);
    try testing.expectEqual(@as(f32, 0.7), rgb[2]);
}

test "postAverage: normal renormalizes to unit length" {
    const rgb = TextureClass.normal_linear.postAverage(0.5, 0.5, 0.0);
    const len = @sqrt(rgb[0] * rgb[0] + rgb[1] * rgb[1] + rgb[2] * rgb[2]);
    try testing.expect(@abs(len - 1.0) < 0.001);
}

test "postAverage: normal preserves direction" {
    const rgb = TextureClass.normal_linear.postAverage(0.0, 0.0, 0.5);
    try testing.expect(@abs(rgb[0]) < 0.001);
    try testing.expect(@abs(rgb[1]) < 0.001);
    try testing.expect(@abs(rgb[2] - 1.0) < 0.001);
}

test "postAverage: normal handles zero vector" {
    const rgb = TextureClass.normal_linear.postAverage(0.0, 0.0, 0.0);
    try testing.expectEqual(@as(f32, 0.0), rgb[0]);
    try testing.expectEqual(@as(f32, 0.0), rgb[1]);
    try testing.expectEqual(@as(f32, 0.0), rgb[2]);
}

test "colorSpace: color_srgb returns srgb" {
    try testing.expectEqual(ColorSpace.srgb, TextureClass.color_srgb.colorSpace());
}

test "colorSpace: normal_linear returns linear" {
    try testing.expectEqual(ColorSpace.linear, TextureClass.normal_linear.colorSpace());
}

test "colorSpace: single_linear returns linear" {
    try testing.expectEqual(ColorSpace.linear, TextureClass.single_linear.colorSpace());
}

test "srgb LUT: entry 0 is 0" {
    try testing.expectEqual(@as(f32, 0.0), TextureClass.srgb_to_linear_lut[0]);
}

test "srgb LUT: entry 255 is ~1.0" {
    try testing.expect(@abs(TextureClass.srgb_to_linear_lut[255] - 1.0) < 0.001);
}

test "srgb LUT: monotonically increasing" {
    for (1..256) |i| {
        try testing.expect(TextureClass.srgb_to_linear_lut[i] >= TextureClass.srgb_to_linear_lut[i - 1]);
    }
}

test "srgb LUT: midpoint is less than 0.5 due to gamma" {
    try testing.expect(TextureClass.srgb_to_linear_lut[128] < 0.25);
}

test "init retains stb-owned decoded pixels" {
    var ppm = [_]u8{
        'P', '6', '\n', '1', ' ', '1', '\n', '2', '5', '5', '\n',
        10,  20,  30,
    };
    const image = try RawTexture.init("pixel.png", &ppm);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(PixelOwner.stb, image.owner);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, image.pixels.ldr);
}

test "deinit leaves borrowed pixels alone" {
    var pixels = [_]u8{ 10, 20, 30, 255 };
    const image = RawTexture{ .width = 1, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    image.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, &pixels);
}

test "getPixel: returns null for out of bounds x" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    const image = RawTexture{ .width = 1, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    try testing.expect(image.getPixel(1, 0) == null);
}

test "getPixel: returns null for out of bounds y" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    const image = RawTexture{ .width = 1, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    try testing.expect(image.getPixel(0, 1) == null);
}

test "getPixel: returns correct pixel data" {
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const image = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    const p0 = image.getPixel(0, 0).?;
    try testing.expectEqual(@as(u8, 10), p0[0]);
    const p1 = image.getPixel(1, 0).?;
    try testing.expectEqual(@as(u8, 50), p1[0]);
}

test "setPixel: writes correct pixel data" {
    var pixels = [_]u8{0} ** 8;
    var image = RawTexture{ .width = 2, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    try image.setPixel(1, 0, &.{ 11, 22, 33, 44 });
    try testing.expectEqual(@as(u8, 11), pixels[4]);
    try testing.expectEqual(@as(u8, 22), pixels[5]);
    try testing.expectEqual(@as(u8, 33), pixels[6]);
    try testing.expectEqual(@as(u8, 44), pixels[7]);
}

test "setPixel: returns error for out of bounds" {
    var pixels = [_]u8{0} ** 4;
    var image = RawTexture{ .width = 1, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    try testing.expectError(error.OutOfBounds, image.setPixel(1, 0, &.{ 0, 0, 0, 0 }));
}

test "setPixel: returns error for wrong color length" {
    var pixels = [_]u8{0} ** 4;
    var image = RawTexture{ .width = 1, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .color_srgb };
    try testing.expectError(error.InvalidColor, image.setPixel(0, 0, &.{ 0, 0, 0 }));
}

test "downsample uses the preceding level" {
    const alloc = testing.allocator;
    var pixels: [8 * 4]u8 = undefined;
    for (0..8) |x| {
        pixels[x * 4 + 0] = @intCast(x * 31);
        pixels[x * 4 + 1] = @intCast(x * 17);
        pixels[x * 4 + 2] = @intCast(x * 9);
        pixels[x * 4 + 3] = @intCast(255 - x * 13);
    }
    const image = RawTexture{ .width = 8, .height = 1, .channels = 4, .pixels = .{ .ldr = &pixels }, .class = .single_linear };
    const scratch = try alloc.alloc(f32, image.mipScratchLen());
    defer alloc.free(scratch);

    var first = try image.downsample(alloc, scratch);
    defer first.deinit(alloc);
    var second = try first.downsample(alloc, scratch);
    defer second.deinit(alloc);
    var direct = try image.downsample(alloc, scratch);
    defer direct.deinit(alloc);
    try testing.expect(!std.mem.eql(u8, direct.pixels.ldr, second.pixels.ldr));
}

test "downsample handles non-power-of-two and single-axis dimensions" {
    const alloc = testing.allocator;
    var npot_pixels = [_]u8{128} ** (5 * 3 * 4);
    const npot = RawTexture{ .width = 5, .height = 3, .channels = 4, .pixels = .{ .ldr = &npot_pixels }, .class = .single_linear };
    const npot_scratch = try alloc.alloc(f32, npot.mipScratchLen());
    defer alloc.free(npot_scratch);
    var npot_next = try npot.downsample(alloc, npot_scratch);
    defer npot_next.deinit(alloc);
    var npot_last = try npot_next.downsample(alloc, npot_scratch);
    defer npot_last.deinit(alloc);
    try testing.expectEqual(@as(u32, 2), npot_next.width);
    try testing.expectEqual(@as(u32, 1), npot_next.height);
    try testing.expectEqual(@as(u32, 1), npot_last.width);
    try testing.expectEqual(@as(u32, 1), npot_last.height);

    var vertical_pixels = [_]u8{128} ** (5 * 4);
    const vertical = RawTexture{ .width = 1, .height = 5, .channels = 4, .pixels = .{ .ldr = &vertical_pixels }, .class = .single_linear };
    const vertical_scratch = try alloc.alloc(f32, vertical.mipScratchLen());
    defer alloc.free(vertical_scratch);
    var vertical_next = try vertical.downsample(alloc, vertical_scratch);
    defer vertical_next.deinit(alloc);
    var vertical_last = try vertical_next.downsample(alloc, vertical_scratch);
    defer vertical_last.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), vertical_next.width);
    try testing.expectEqual(@as(u32, 2), vertical_next.height);
    try testing.expectEqual(@as(u32, 1), vertical_last.width);
    try testing.expectEqual(@as(u32, 1), vertical_last.height);
}
