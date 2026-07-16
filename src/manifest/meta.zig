const std = @import("std");
const AssetId = @import("../id/id_types.zig").AssetId;
const errors = @import("errors.zig");

pub const meta_format = "zephyr.assetmeta";
pub const meta_version: u32 = 1;
pub const meta_extension = ".zmeta";
pub const max_meta_bytes: usize = 16 * 1024;

/// A `.zmeta` sidecar: the durable identity of one authored source asset.
/// Sidecars sit next to their source file, are committed to version
/// control, and are the identity source of truth — deleting one assigns a
/// NEW id on the next cook and breaks every reference to the asset.
pub const AssetMeta = struct {
    format: []const u8 = meta_format,
    version: u32 = meta_version,
    id: AssetId,
    /// Cooker that owns this source, e.g. "glb", "tex", "shader", "material".
    /// Empty until cooker identity is wired into the manifest builder.
    importer: []const u8 = "",
    /// Bumped by a cooker when its output format/logic changes.
    importer_version: u32 = 0,

    pub fn validate(self: *const AssetMeta) errors.MetaError!void {
        if (!std.mem.eql(u8, self.format, meta_format)) return error.InvalidMetaFormat;
        if (self.version == 0 or self.version > meta_version) return error.UnsupportedMetaVersion;
        if (self.id.isZero()) return error.ZeroMetaId;
    }
};

/// Parses sidecar bytes. All strings are allocated from `allocator`
/// (arena recommended; MetaStore owns one).
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !AssetMeta {
    const meta = std.json.parseFromSliceLeaky(AssetMeta, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true, // forward compat: newer fields skipped
    }) catch return error.CorruptMeta;
    try meta.validate();
    return meta;
}

/// Canonical serialization: 2-space indent, struct field order, trailing
/// newline. Byte-stable for identical inputs so recooks never dirty VCS.
pub fn serialize(allocator: std.mem.Allocator, meta: *const AssetMeta) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(allocator, meta, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(body);
    return std.mem.concat(allocator, u8, &.{ body, "\n" });
}

/// "meshes/monkey.glb" -> "meshes/monkey.glb.zmeta"
pub fn metaPathFor(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ source_path, meta_extension });
}

pub fn isMetaPath(p: []const u8) bool {
    return std.mem.endsWith(u8, p, meta_extension);
}

const testing = std.testing;

test "parse/serialize roundtrip is byte-stable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const meta = AssetMeta{
        .id = try AssetId.parse("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01"),
        .importer = "glb",
        .importer_version = 1,
    };
    const bytes1 = try serialize(a, &meta);
    const reparsed = try parse(a, bytes1);
    const bytes2 = try serialize(a, &reparsed);
    try testing.expectEqualStrings(bytes1, bytes2);
}

test "parse rejects zero id, wrong format, future version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.ZeroMetaId, parse(a,
        \\{"format":"zephyr.assetmeta","version":1,"id":"00000000-0000-0000-0000-000000000000"}
    ));
    try testing.expectError(error.InvalidMetaFormat, parse(a,
        \\{"format":"nope","version":1,"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01"}
    ));
    try testing.expectError(error.UnsupportedMetaVersion, parse(a,
        \\{"format":"zephyr.assetmeta","version":99,"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01"}
    ));
    try testing.expectError(error.CorruptMeta, parse(a, "not json"));
}

test "parse tolerates unknown fields from newer writers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const meta = try parse(arena.allocator(),
        \\{"format":"zephyr.assetmeta","version":1,
        \\ "id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01",
        \\ "importer":"glb","importer_version":2,
        \\ "some_future_field":{"x":1}}
    );
    try testing.expectEqualStrings("glb", meta.importer);
}

test "metaPathFor and isMetaPath" {
    const p = try metaPathFor(testing.allocator, "meshes/monkey.glb");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("meshes/monkey.glb.zmeta", p);

    try testing.expect(isMetaPath("meshes/monkey.glb.zmeta"));
    try testing.expect(isMetaPath(".zmeta"));
    try testing.expect(!isMetaPath("meshes/monkey.glb"));
    try testing.expect(!isMetaPath("weird.zmeta.glb"));
}
