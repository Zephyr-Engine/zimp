const std = @import("std");

const Image = struct {
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
