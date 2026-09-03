const std = @import("std");
const mesh_format = @import("formats/zmesh.zig");
const texture_format = @import("formats/ztex.zig");
const shader_format = @import("formats/zshdr.zig");
const material_format = @import("formats/zamat.zig");
const path_helpers = @import("path.zig");
const wire = @import("shared/wire.zig");
pub const AssetKind = @import("assets/asset.zig").AssetKind;

pub const Asset = union(enum) {
    mesh: mesh_format.ZMesh,
    texture: texture_format.Zatex,
    shader: shader_format.ZShader,
    material: material_format.Zamat,

    pub fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .mesh => |*m| m.deinit(allocator),
            .texture => |*t| t.deinit(allocator),
            .shader => |*s| s.deinit(allocator),
            .material => |*m| m.deinit(allocator),
        }
    }
};

pub const CookedStore = struct {
    root: []u8,
    dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !CookedStore {
        const cwd = std.Io.Dir.cwd();
        const dir = try std.Io.Dir.openDir(cwd, io, root, .{});
        errdefer dir.close(io);
        return initFromDir(allocator, root, dir);
    }

    pub fn initFromDir(allocator: std.mem.Allocator, root: []const u8, dir: std.Io.Dir) !CookedStore {
        return .{
            .root = try allocator.dupe(u8, root),
            .dir = dir,
        };
    }

    pub fn deinit(self: *CookedStore, allocator: std.mem.Allocator, io: std.Io) void {
        self.dir.close(io);
        allocator.free(self.root);
    }

    pub fn readAlloc(
        self: *CookedStore,
        allocator: std.mem.Allocator,
        io: std.Io,
        normalized_path: []const u8,
    ) ![]u8 {
        try path_helpers.validateVirtual(normalized_path);
        return self.dir.readFileAlloc(io, normalized_path, allocator, .limited(wire.max_asset_bytes));
    }
};

pub fn detectKind(path: []const u8) ?AssetKind {
    return AssetKind.fromCookedPath(path);
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Asset {
    const normalized_path = try path_helpers.normalizeVirtual(allocator, path);
    defer allocator.free(normalized_path);

    const asset_kind = detectKind(normalized_path) orelse return error.UnsupportedAssetType;

    const file = try dir.openFile(io, normalized_path, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return loadFromReader(allocator, &file_reader.interface, asset_kind);
}

pub fn loadFromReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    asset_kind: AssetKind,
) !Asset {
    switch (asset_kind) {
        .mesh => return .{ .mesh = try mesh_format.read(allocator, reader) },
        .texture => return .{ .texture = try texture_format.read(allocator, reader) },
        .shader_stage => return .{ .shader = try shader_format.read(allocator, reader) },
        .material => return .{ .material = try material_format.read(allocator, reader) },
    }
}

const testing = std.testing;

test "detectKind maps cooked asset extensions" {
    try testing.expectEqual(AssetKind.mesh, detectKind("monkey.zmesh").?);
    try testing.expectEqual(AssetKind.material, detectKind("monkey.zamat").?);
    try testing.expectEqual(AssetKind.texture, detectKind("brick_albedo.ztex").?);
    try testing.expectEqual(AssetKind.shader_stage, detectKind("basic.vert.zshdr").?);
}

test "detectKind requires lowercase cooked extensions" {
    try testing.expect(detectKind("MONKEY.ZMESH") == null);
}

test "loadFromFile loads zmesh" {
    const mesh_mod = @import("assets/cooked/mesh.zig");
    const raw_mesh = @import("assets/raw/mesh.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const verts = [_]mesh_mod.CookedVertex{
        .{ .position = .{ 0, 0, 0 }, .normal = null, .tangent = null, .uv0 = null, .uv1 = null, .joint_indices = null, .joint_weights = null },
        .{ .position = .{ 1, 0, 0 }, .normal = null, .tangent = null, .uv0 = null, .uv1 = null, .joint_indices = null, .joint_weights = null },
        .{ .position = .{ 0, 1, 0 }, .normal = null, .tangent = null, .uv0 = null, .uv1 = null, .joint_indices = null, .joint_weights = null },
    };
    const cooked = mesh_mod.CookedMesh{
        .vertices = @constCast(&verts),
        .indices = .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null },
        .submeshes = @constCast(&[_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 3, .material_index = 0 }}),
        .format_flags = .{},
        .bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } },
        .name = null,
    };

    const file = try tmp.dir.createFile(testing.io, "test.zmesh", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    const parts = [_]mesh_format.ZMesh.CookPart{.{ .mesh = cooked, .transform = mesh_format.identity_transform }};
    const material_slots = [_][]const u8{"materials/test.zamat"};
    try mesh_format.write(&writer.interface, &material_slots, &parts);
    try writer.flush();
    file.close(testing.io);

    var asset = try loadFromFile(testing.allocator, testing.io, tmp.dir, "test.zmesh");
    defer asset.deinit(testing.allocator);

    try testing.expect(asset == .mesh);
    try testing.expectEqual(@as(usize, 1), asset.mesh.parts.len);
    try testing.expectEqual(@as(u32, 3), asset.mesh.parts[0].mesh.vertex_count);
}

test "loadFromFile rejects unknown extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.UnsupportedAssetType, loadFromFile(testing.allocator, testing.io, tmp.dir, "unknown.xyz"));
}

test "Asset deinit frees resources" {
    const mesh_mod = @import("assets/cooked/mesh.zig");
    const raw_mesh = @import("assets/raw/mesh.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const verts = [_]mesh_mod.CookedVertex{
        .{ .position = .{ 0, 0, 0 }, .normal = null, .tangent = null, .uv0 = null, .uv1 = null, .joint_indices = null, .joint_weights = null },
    };
    const cooked = mesh_mod.CookedMesh{
        .vertices = @constCast(&verts),
        .indices = .{ .u16 = @constCast(&[_]u16{0}), .u32 = null },
        .submeshes = @constCast(&[_]raw_mesh.RawSubmesh{.{ .index_offset = 0, .index_count = 1, .material_index = 0 }}),
        .format_flags = .{},
        .bounds = .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } },
        .name = null,
    };

    const file = try tmp.dir.createFile(testing.io, "test.zmesh", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    const parts = [_]mesh_format.ZMesh.CookPart{.{ .mesh = cooked, .transform = mesh_format.identity_transform }};
    const material_slots = [_][]const u8{"materials/test.zamat"};
    try mesh_format.write(&writer.interface, &material_slots, &parts);
    try writer.flush();
    file.close(testing.io);

    var asset = try loadFromFile(testing.allocator, testing.io, tmp.dir, "test.zmesh");
    asset.deinit(testing.allocator);
    // deinit should not crash
}
