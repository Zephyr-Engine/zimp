const std = @import("std");

pub const stb = @cImport({
    @cInclude("stb_image.h");
});

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u32, // always 4 after decode (RGBA)
    pixels: []u8, // length = width * height * channels
    class: TextureClass,

    pub fn init(filename: []const u8, file_bytes: []u8) Image {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const pixels = stb.stbi_load_from_memory(
            file_bytes.ptr,
            @intCast(file_bytes.len),
            &width,
            &height,
            &channels,
            4,
        );
        defer stb.stbi_image_free(pixels);

        const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;

        const image = Image{
            .width = @as(u32, @intCast(width)),
            .height = @as(u32, @intCast(height)),
            .channels = 4,
            .pixels = pixels[0..len],
            .class = TextureClass.classify(filename),
        };
        return image;
    }

    pub fn getPixel(self: *const Image, x: u32, y: u32) ?[]const u8 {
        if (x >= self.width or y >= self.height) {
            return null;
        }

        const idx = @as(usize, (y * self.width + x) * self.channels);
        return self.pixels[idx .. idx + self.channels];
    }

    pub fn setPixel(self: *Image, x: u32, y: u32, color: []const u8) !void {
        if (x >= self.width or y >= self.height) {
            return error.OutOfBounds;
        }
        if (color.len != self.channels) {
            return error.InvalidColor;
        }

        const idx = @as(usize, (y * self.width + x) * self.channels);
        std.mem.copyForwards(u8, self.pixels[idx .. idx + self.channels], color);
    }

    pub fn generateMipmaps(self: *const Image, allocator: std.mem.Allocator) ![]Image {
        const count = std.math.log2(@max(self.width, self.height)) + 1;

        const images = try allocator.alloc(Image, count);
        for (0..count) |i| {
            const shift: u5 = @intCast(i);
            const mip_width = @max(1, self.width >> shift);
            const mip_height = @max(1, self.height >> shift);

            const bytes = try allocator.alloc(u8, @as(usize, mip_width) * @as(usize, mip_height) * self.channels);

            var image = Image{
                .width = mip_width,
                .height = mip_height,
                .channels = self.channels,
                .pixels = bytes,
                .class = self.class,
            };
            try self.boxFilter(&image);

            images[i] = image;
        }

        return images;
    }

    fn boxFilter(original_image: *const Image, new_image: *Image) !void {
        const class = original_image.class;

        for (0..new_image.height) |y| {
            for (0..new_image.width) |x| {
                var r: f32 = 0;
                var g: f32 = 0;
                var b: f32 = 0;
                var a: f32 = 0;
                var count: f32 = 0;

                for (0..2) |j| {
                    for (0..2) |i| {
                        const src_x = @min(original_image.width - 1, x * 2 + i);
                        const src_y = @min(original_image.height - 1, y * 2 + j);
                        if (original_image.getPixel(src_x, src_y)) |color| {
                            r += class.decode(color[0]);
                            g += class.decode(color[1]);
                            b += class.decode(color[2]);
                            a += @as(f32, @floatFromInt(color[3])) / 255.0;
                            count += 1;
                        }
                    }
                }

                const inv = 1.0 / count;
                const rgb = class.postAverage(r * inv, g * inv, b * inv);
                const avg_color = [4]u8{
                    class.encode(rgb[0]),
                    class.encode(rgb[1]),
                    class.encode(rgb[2]),
                    @intFromFloat(std.math.clamp(a * inv, 0.0, 1.0) * 255.0 + 0.5),
                };
                try new_image.setPixel(@intCast(x), @intCast(y), &avg_color);
            }
        }
    }
};

const ColorSpace = enum {
    srgb,
    linear,
};

const TextureClass = enum {
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

test "getPixel: returns null for out of bounds x" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    const image = Image{ .width = 1, .height = 1, .channels = 4, .pixels = &pixels, .class = .color_srgb };
    try testing.expect(image.getPixel(1, 0) == null);
}

test "getPixel: returns null for out of bounds y" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    const image = Image{ .width = 1, .height = 1, .channels = 4, .pixels = &pixels, .class = .color_srgb };
    try testing.expect(image.getPixel(0, 1) == null);
}

test "getPixel: returns correct pixel data" {
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const image = Image{ .width = 2, .height = 1, .channels = 4, .pixels = &pixels, .class = .color_srgb };
    const p0 = image.getPixel(0, 0).?;
    try testing.expectEqual(@as(u8, 10), p0[0]);
    const p1 = image.getPixel(1, 0).?;
    try testing.expectEqual(@as(u8, 50), p1[0]);
}

test "setPixel: writes correct pixel data" {
    var pixels = [_]u8{0} ** 8;
    var image = Image{ .width = 2, .height = 1, .channels = 4, .pixels = &pixels, .class = .color_srgb };
    try image.setPixel(1, 0, &.{ 11, 22, 33, 44 });
    try testing.expectEqual(@as(u8, 11), pixels[4]);
    try testing.expectEqual(@as(u8, 22), pixels[5]);
    try testing.expectEqual(@as(u8, 33), pixels[6]);
    try testing.expectEqual(@as(u8, 44), pixels[7]);
}

test "setPixel: returns error for out of bounds" {
    var pixels = [_]u8{0} ** 4;
    var image = Image{ .width = 1, .height = 1, .channels = 4, .pixels = &pixels, .class = .color_srgb };
    try testing.expectError(error.OutOfBounds, image.setPixel(1, 0, &.{ 0, 0, 0, 0 }));
}

test "setPixel: returns error for wrong color length" {
    var pixels = [_]u8{0} ** 4;
    var image = Image{ .width = 1, .height = 1, .channels = 4, .pixels = &pixels, .class = .color_srgb };
    try testing.expectError(error.InvalidColor, image.setPixel(0, 0, &.{ 0, 0, 0 }));
}

test "generateMipmaps: 4x4 produces correct mip count" {
    const alloc = testing.allocator;
    var pixels = [_]u8{128} ** (4 * 4 * 4);
    const image = Image{ .width = 4, .height = 4, .channels = 4, .pixels = &pixels, .class = .single_linear };
    const mipmaps = try image.generateMipmaps(alloc);
    defer {
        for (mipmaps) |mip| alloc.free(mip.pixels);
        alloc.free(mipmaps);
    }
    try testing.expectEqual(@as(usize, 3), mipmaps.len);
    try testing.expectEqual(@as(u32, 4), mipmaps[0].width);
    try testing.expectEqual(@as(u32, 2), mipmaps[1].width);
    try testing.expectEqual(@as(u32, 1), mipmaps[2].width);
}

test "generateMipmaps: uniform linear image preserves value" {
    const alloc = testing.allocator;
    var pixels = [_]u8{100} ** (4 * 4 * 4);
    const image = Image{ .width = 4, .height = 4, .channels = 4, .pixels = &pixels, .class = .single_linear };
    const mipmaps = try image.generateMipmaps(alloc);
    defer {
        for (mipmaps) |mip| alloc.free(mip.pixels);
        alloc.free(mipmaps);
    }
    const smallest = mipmaps[mipmaps.len - 1];
    try testing.expectEqual(@as(u8, 100), smallest.pixels[0]);
    try testing.expectEqual(@as(u8, 100), smallest.pixels[1]);
    try testing.expectEqual(@as(u8, 100), smallest.pixels[2]);
    try testing.expectEqual(@as(u8, 100), smallest.pixels[3]);
}

test "generateMipmaps: normal mip is renormalized" {
    const alloc = testing.allocator;
    var pixels = [_]u8{ 128, 128, 255, 255 } ** (2 * 2);
    const image = Image{ .width = 2, .height = 2, .channels = 4, .pixels = &pixels, .class = .normal_linear };
    const mipmaps = try image.generateMipmaps(alloc);
    defer {
        for (mipmaps) |mip| alloc.free(mip.pixels);
        alloc.free(mipmaps);
    }
    const mip1 = mipmaps[1];
    try testing.expect(mip1.pixels[2] > 250);
}

test "generateMipmaps: mips inherit texture class" {
    const alloc = testing.allocator;
    var pixels = [_]u8{128} ** (2 * 2 * 4);
    const image = Image{ .width = 2, .height = 2, .channels = 4, .pixels = &pixels, .class = .normal_linear };
    const mipmaps = try image.generateMipmaps(alloc);
    defer {
        for (mipmaps) |mip| alloc.free(mip.pixels);
        alloc.free(mipmaps);
    }
    for (mipmaps) |mip| {
        try testing.expectEqual(TextureClass.normal_linear, mip.class);
    }
}
