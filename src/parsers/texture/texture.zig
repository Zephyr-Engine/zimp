const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u32, // always 4 after decode (RGBA)
    pixels: []u8, // length = width * height * channels

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
            };
            try self.boxFilter(&image);

            images[i] = image;
        }

        return images;
    }

    fn boxFilter(original_image: *const Image, new_image: *Image) !void {
        for (0..new_image.height) |y| {
            for (0..new_image.width) |x| {
                var r: u32 = 0;
                var g: u32 = 0;
                var b: u32 = 0;
                var a: u32 = 0;
                var count: u32 = 0;

                for (0..2) |j| {
                    for (0..2) |i| {
                        const src_x = @min(original_image.width - 1, x * 2 + i);
                        const src_y = @min(original_image.height - 1, y * 2 + j);
                        if (original_image.getPixel(src_x, src_y)) |color| {
                            r += color[0];
                            g += color[1];
                            b += color[2];
                            a += color[3];
                            count += 1;
                        }
                    }
                }

                const avg_color = [4]u8{
                    @intCast(r / count),
                    @intCast(g / count),
                    @intCast(b / count),
                    @intCast(a / count),
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
