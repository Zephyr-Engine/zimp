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

    const srgb_to_linear_lut: [256]f32 = blk: {
        var lut: [256]f32 = undefined;
        for (0..256) |i| {
            const f: f32 = @as(f32, @floatFromInt(i)) / 255.0;
            lut[i] = if (f > 0) @exp(@log(f) * 2.2) else 0.0;
        }
        break :blk lut;
    };

    fn srgbToLinear(v: u8) f32 {
        return srgb_to_linear_lut[v];
    }

    fn linearToSrgb(v: f32) u8 {
        const clamped = std.math.clamp(v, 0.0, 1.0);
        return @intFromFloat(std.math.pow(f32, clamped, 1.0 / 2.2) * 255.0 + 0.5);
    }

    fn byteToSigned(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0 * 2.0 - 1.0;
    }

    fn signedToByte(v: f32) u8 {
        return @intFromFloat(std.math.clamp((v + 1.0) * 0.5 * 255.0 + 0.5, 0.0, 255.0));
    }

    fn boxFilter(original_image: *const Image, new_image: *Image) !void {
        const srgb = original_image.class.colorSpace() == .srgb;
        const is_normal = original_image.class == .normal_linear;

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
                            if (srgb) {
                                r += srgbToLinear(color[0]);
                                g += srgbToLinear(color[1]);
                                b += srgbToLinear(color[2]);
                            } else if (is_normal) {
                                r += byteToSigned(color[0]);
                                g += byteToSigned(color[1]);
                                b += byteToSigned(color[2]);
                            } else {
                                r += @as(f32, @floatFromInt(color[0])) / 255.0;
                                g += @as(f32, @floatFromInt(color[1])) / 255.0;
                                b += @as(f32, @floatFromInt(color[2])) / 255.0;
                            }
                            a += @as(f32, @floatFromInt(color[3])) / 255.0;
                            count += 1;
                        }
                    }
                }

                const inv = 1.0 / count;
                const avg_color = if (srgb) [4]u8{
                    linearToSrgb(r * inv),
                    linearToSrgb(g * inv),
                    linearToSrgb(b * inv),
                    @intFromFloat(std.math.clamp(a * inv, 0.0, 1.0) * 255.0 + 0.5),
                } else if (is_normal) blk: {
                    const nx = r * inv;
                    const ny = g * inv;
                    const nz = b * inv;
                    const len = @sqrt(nx * nx + ny * ny + nz * nz);
                    const s = if (len > 0.0) 1.0 / len else 0.0;
                    break :blk [4]u8{
                        signedToByte(nx * s),
                        signedToByte(ny * s),
                        signedToByte(nz * s),
                        @intFromFloat(std.math.clamp(a * inv, 0.0, 1.0) * 255.0 + 0.5),
                    };
                } else [4]u8{
                    @intFromFloat(std.math.clamp(r * inv, 0.0, 1.0) * 255.0 + 0.5),
                    @intFromFloat(std.math.clamp(g * inv, 0.0, 1.0) * 255.0 + 0.5),
                    @intFromFloat(std.math.clamp(b * inv, 0.0, 1.0) * 255.0 + 0.5),
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

    pub fn colorSpace(self: TextureClass) ColorSpace {
        return switch (self) {
            .color_srgb => .srgb,
            else => .linear,
        };
    }
};
