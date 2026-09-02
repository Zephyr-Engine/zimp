const std = @import("std");
const ids = @import("../id/id_types.zig");

pub fn assetIdForPath(project_id: ids.ProjectId, path: []const u8) ids.AssetId {
    return ids.AssetId.derive(project_id.uuid, path);
}

const testing = std.testing;

const project_a = ids.ProjectId.parseComptime(
    "bf5a424f-e93e-4977-9a7a-0c522318dfdc",
);
const project_b = ids.ProjectId.parseComptime(
    "b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4",
);

test "assetIdForPath is deterministic and path-sensitive" {
    const first = assetIdForPath(project_a, "meshes/monkey.glb");
    const again = assetIdForPath(project_a, "meshes/monkey.glb");
    const moved = assetIdForPath(project_a, "models/monkey.glb");

    try testing.expect(first.eql(again));
    try testing.expect(!first.eql(moved));
    try testing.expect(!first.isZero());
}

test "assetIdForPath is scoped by project id" {
    const first = assetIdForPath(project_a, "meshes/monkey.glb");
    const second = assetIdForPath(project_b, "meshes/monkey.glb");

    try testing.expect(!first.eql(second));
}

test "assetIdForPath golden value is stable across releases" {
    const id = assetIdForPath(project_a, "meshes/monkey.glb");

    try testing.expectEqualStrings(
        "5313054d-3f6a-8e9b-b102-fa2bf68d10d5",
        &id.toString(),
    );
}
