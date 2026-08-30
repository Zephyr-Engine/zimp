/// Compatibility import for manifest consumers. AssetKind itself is defined
/// with source/cooked asset metadata in assets/asset.zig.
pub const AssetKind = @import("../assets/asset.zig").AssetKind;

const std = @import("std");
const testing = std.testing;

test "fromInt rejects unknown tags" {
    try testing.expectEqual(AssetKind.material, AssetKind.fromInt(3).?);
    try testing.expect(AssetKind.fromInt(4) == null);
    try testing.expect(AssetKind.fromInt(255) == null);
}
