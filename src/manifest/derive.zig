const std = @import("std");
const Uuid = @import("../id/uuid.zig").Uuid;
const AssetId = @import("../id/id_types.zig").AssetId;

// Namespaces for derived (v8) ids. NEVER change these values; they are baked
// into every derived id ever emitted. See docs/identity.md in the main repo.

/// Fixed namespace for IDs derived from a generated asset's source path.
pub const ns_generated_path: Uuid = Uuid.parseComptime("7a0e3d4c-915b-4f27-8c1d-6602b3f4a910");

/// Reserved for future "sub-asset of X" identity (e.g. glTF sub-meshes).
/// Unused today; frozen now so it can never collide with another namespace.
pub const ns_sub_asset: Uuid = Uuid.parseComptime("41c7f2aa-6e0b-4f7d-9b3c-8d15e2a90c64");

/// Reserved for fixed engine component type ids (component schema plan).
pub const ns_engine_component: Uuid = Uuid.parseComptime("c65f1d02-83b4-4f5a-a2ce-490be1a7d310");

/// Deterministic id for a cook-generated asset (`generated/**`): a pure
/// function of the source path, stable forever, on every machine.
pub fn generatedAssetId(source_path: []const u8) AssetId {
    return AssetId.derive(ns_generated_path, source_path);
}

const testing = std.testing;

test "generatedAssetId is deterministic and input-sensitive" {
    const a = generatedAssetId("generated/materials/monkey_Suzanne.zamat");
    const b = generatedAssetId("generated/materials/monkey_Suzanne.zamat");
    const c = generatedAssetId("generated/materials/monkey_Other.zamat");
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.isZero());
}

test "golden generated id is stable across releases" {
    // If this test ever fails, derived identity broke for every project.
    // Never update this literal.
    const id = generatedAssetId("generated/materials/golden.zamat");
    try testing.expectEqualStrings("cde59dc1-afbd-8740-b00d-adee8cb339ce", &id.toString());
}
