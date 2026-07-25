const std = @import("std");

pub const AssetType = enum {
    mesh,
    texture,
    shader,
    material,
    unknown,

    pub fn cookedExtension(self: AssetType) []const u8 {
        return switch (self) {
            .mesh => "zmesh",
            .texture => "ztex",
            .shader => "zshdr",
            .material => "zamat",
            .unknown => "",
        };
    }

    pub fn rebuildsOnHostOsChange(self: AssetType) bool {
        return switch (self) {
            .material => true,
            .mesh, .texture, .shader, .unknown => false,
        };
    }

    pub fn fromCookedPath(path: []const u8) ?AssetType {
        for (std.enums.values(AssetType)) |asset_type| {
            if (asset_type == .unknown) continue;
            const extension = asset_type.cookedExtension();
            if (std.mem.endsWith(u8, path, extension) and
                path.len > extension.len and path[path.len - extension.len - 1] == '.')
                return asset_type;
        }
        return null;
    }
};

pub const Extension = enum {
    gltf,
    glb,
    obj,
    bin,
    png,
    jpg,
    jpeg,
    hdr,
    vert,
    frag,
    comp,
    glsl,
    zamat,
    other,

    pub fn string(self: Extension) []const u8 {
        return @tagName(self);
    }

    pub fn assetType(self: Extension) AssetType {
        return switch (self) {
            .gltf, .glb, .obj => .mesh,
            .png, .jpg, .jpeg, .hdr => .texture,
            .vert, .frag, .comp, .glsl => .shader,
            .zamat => .material,
            .bin, .other => .unknown,
        };
    }

    pub fn fromName(name: []const u8) Extension {
        const dotted_ext = std.fs.path.extension(name);
        if (dotted_ext.len > 1) {
            return std.meta.stringToEnum(Extension, dotted_ext[1..]) orelse .other;
        }
        return .other;
    }

    pub fn processEntry(entry: std.Io.Dir.Entry) Extension {
        return fromName(entry.name);
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

test "Extension.assetType maps glsl to shader" {
    try testing.expectEqual(.shader, Extension.glsl.assetType());
}

test "Extension.assetType maps other to unknown" {
    try testing.expectEqual(.unknown, Extension.other.assetType());
}

test "AssetType.rebuildsOnHostOsChange marks only OS-sensitive assets" {
    try testing.expect(AssetType.material.rebuildsOnHostOsChange());
    try testing.expect(!AssetType.mesh.rebuildsOnHostOsChange());
    try testing.expect(!AssetType.texture.rebuildsOnHostOsChange());
    try testing.expect(!AssetType.shader.rebuildsOnHostOsChange());
    try testing.expect(!AssetType.unknown.rebuildsOnHostOsChange());
}

test "Extension.processEntry returns gltf for .gltf file" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "model.gltf", .kind = .file };
    try testing.expectEqual(.gltf, Extension.processEntry(entry));
}

test "Extension.processEntry returns png for .png file" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "image.png", .kind = .file };
    try testing.expectEqual(.png, Extension.processEntry(entry));
}

test "Extension.processEntry uses final extension for multi-dot names" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "basic.mobile.frag", .kind = .file };
    try testing.expectEqual(.frag, Extension.processEntry(entry));
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
