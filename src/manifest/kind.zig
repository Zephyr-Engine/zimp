const std = @import("std");
const AssetType = @import("../assets/asset.zig").AssetType;

/// Persisted asset kind. Tag values are wire format — append only, never
/// renumber, never reuse a retired value.
pub const AssetKind = enum(u8) {
    mesh = 0,
    texture = 1,
    shader_stage = 2,
    material = 3,

    /// Cook-side conversion. `unknown` sources (dependency-only files such
    /// as .bin buffers and .glsl includes) are not manifest assets.
    pub fn fromAssetType(t: AssetType) ?AssetKind {
        return switch (t) {
            .mesh => .mesh,
            .texture => .texture,
            .shader => .shader_stage,
            .material => .material,
            .unknown => null,
        };
    }

    pub fn toAssetType(self: AssetKind) AssetType {
        return switch (self) {
            .mesh => .mesh,
            .texture => .texture,
            .shader_stage => .shader,
            .material => .material,
        };
    }

    /// Strict decode for values read from files.
    pub fn fromInt(raw: u8) ?AssetKind {
        return switch (raw) {
            0 => .mesh,
            1 => .texture,
            2 => .shader_stage,
            3 => .material,
            else => null,
        };
    }

    pub fn displayName(self: AssetKind) []const u8 {
        return switch (self) {
            .mesh => "mesh",
            .texture => "texture",
            .shader_stage => "shader stage",
            .material => "material",
        };
    }
};

const testing = std.testing;

test "fromAssetType excludes unknown" {
    try testing.expectEqual(AssetKind.mesh, AssetKind.fromAssetType(.mesh).?);
    try testing.expectEqual(AssetKind.shader_stage, AssetKind.fromAssetType(.shader).?);
    try testing.expect(AssetKind.fromAssetType(.unknown) == null);
}

test "fromInt rejects unknown tags" {
    try testing.expectEqual(AssetKind.material, AssetKind.fromInt(3).?);
    try testing.expect(AssetKind.fromInt(4) == null);
    try testing.expect(AssetKind.fromInt(255) == null);
}

test "toAssetType/fromAssetType roundtrip" {
    inline for (@typeInfo(AssetKind).@"enum".fields) |f| {
        const kind: AssetKind = @enumFromInt(f.value);
        try testing.expectEqual(kind, AssetKind.fromAssetType(kind.toAssetType()).?);
    }
}
