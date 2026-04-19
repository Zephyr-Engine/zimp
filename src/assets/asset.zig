const std = @import("std");

pub const AssetType = enum {
    mesh,
    texture,
    shader,
    unknown,

    pub fn cookedExtension(self: AssetType) []const u8 {
        return switch (self) {
            .mesh => "zmesh",
            .texture => "ztex",
            .shader => "zshdr",
            .unknown => "",
        };
    }
};

const asset_map = std.EnumArray(Extension, AssetType).init(.{
    .gltf = .mesh,
    .glb = .mesh,
    .obj = .mesh,
    .png = .texture,
    .jpg = .texture,
    .jpeg = .texture,
    .hdr = .texture,
    .vert = .shader,
    .frag = .shader,
    .comp = .shader,
    .glsl = .shader,
    .other = .unknown,
});

const extension_map = std.StaticStringMap(Extension).initComptime(.{
    .{ "gltf", .gltf },
    .{ "glb", .glb },
    .{ "obj", .obj },
    .{ "png", .png },
    .{ "jpg", .jpg },
    .{ "jpeg", .jpeg },
    .{ "hdr", .hdr },
    .{ "vert", .vert },
    .{ "frag", .frag },
    .{ "comp", .comp },
    .{ "glsl", .glsl },
});

pub const Extension = enum {
    gltf,
    glb,
    obj,
    png,
    jpg,
    jpeg,
    hdr,
    vert,
    frag,
    comp,
    glsl,
    other,

    pub fn string(self: Extension) []const u8 {
        return switch (self) {
            .gltf => "gltf",
            .glb => "glb",
            .obj => "obj",
            .png => "png",
            .jpg => "jpg",
            .jpeg => "jpeg",
            .hdr => "hdr",
            .vert => "vert",
            .frag => "frag",
            .comp => "comp",
            .glsl => "glsl",
            .other => "other",
        };
    }

    pub fn assetType(self: Extension) AssetType {
        return asset_map.get(self);
    }

    pub fn processEntry(entry: std.Io.Dir.Entry) Extension {
        var iter = std.mem.splitScalar(u8, entry.name, '.');
        // ignore filename itself
        _ = iter.next();

        if (iter.next()) |ext| {
            if (extension_map.get(ext)) |ex| {
                return ex;
            }
        }
        return .other;
    }
};

const testing = std.testing;

test "Extension.string returns correct string for gltf" {
    try testing.expectEqualStrings("gltf", Extension.gltf.string());
}

test "Extension.string returns correct string for other" {
    try testing.expectEqualStrings("other", Extension.other.string());
}

test "Extension.assetType maps gltf to mesh" {
    try testing.expectEqual(.mesh, Extension.gltf.assetType());
}

test "Extension.assetType maps other to unknown" {
    try testing.expectEqual(.unknown, Extension.other.assetType());
}

test "Extension.processEntry returns gltf for .gltf file" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "model.gltf", .kind = .file };
    try testing.expectEqual(.gltf, Extension.processEntry(entry));
}

test "Extension.processEntry returns png for .png file" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "image.png", .kind = .file };
    try testing.expectEqual(.png, Extension.processEntry(entry));
}

test "Extension.processEntry returns other for unknown extension" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "data.csv", .kind = .file };
    try testing.expectEqual(.other, Extension.processEntry(entry));
}

test "Extension.processEntry returns other for file with no extension" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "README", .kind = .file };
    try testing.expectEqual(.other, Extension.processEntry(entry));
}

test "Extension.processEntry returns other for dotfile" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = ".gitignore", .kind = .file };
    try testing.expectEqual(.other, Extension.processEntry(entry));
}
