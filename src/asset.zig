const std = @import("std");

pub const AssetType = enum {
    mesh,
    unknown,
};

const asset_map = std.EnumArray(Extension, AssetType).init(.{
    .gltf = .mesh,
    .other = .unknown,
});

const extension_map = std.StaticStringMap(Extension).initComptime(.{
    .{ "gltf", .gltf },
});

pub const Extension = enum {
    gltf,
    other,

    pub fn string(self: Extension) []const u8 {
        return switch (self) {
            .gltf => "gltf",
            .other => "other",
        };
    }

    pub fn assetType(self: Extension) AssetType {
        return asset_map.get(self);
    }

    // find extension from file
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
