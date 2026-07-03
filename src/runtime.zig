const std = @import("std");
const ZMesh = @import("formats/zmesh.zig").ZMesh;
const Zatex = @import("formats/ztex.zig").Zatex;
const ZShader = @import("formats/zshdr.zig").ZShader;
const Zamat = @import("formats/zamat.zig").Zamat;
const path_helpers = @import("path.zig");
pub const AssetType = @import("assets/asset.zig").AssetType;

pub const Asset = union(enum) {
    mesh: ZMesh,
    texture: Zatex,
    shader: ZShader,
    material: Zamat,

    pub fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .mesh => |*m| m.deinit(allocator),
            .texture => |*t| t.deinit(allocator),
            .shader => |*s| s.deinit(allocator),
            .material => |*m| m.deinit(allocator),
        }
    }
};

pub const CookedAsset = Asset;

pub const CookedStore = struct {
    root: []u8,
    dir: std.Io.Dir,

    const max_asset_bytes: usize = 512 * 1024 * 1024;

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
        return self.dir.readFileAlloc(io, normalized_path, allocator, .limited(max_asset_bytes));
    }
};

pub const PathError = path_helpers.Error;
pub const max_virtual_path_len = path_helpers.max_virtual_path_len;

pub fn detectType(path: []const u8) ?AssetType {
    if (std.mem.endsWith(u8, path, ".zmesh")) return .mesh;
    if (std.mem.endsWith(u8, path, ".ztex")) return .texture;
    if (std.mem.endsWith(u8, path, ".zshdr")) return .shader;
    if (std.mem.endsWith(u8, path, ".zamat")) return .material;
    return null;
}

pub fn normalizeVirtualPath(allocator: std.mem.Allocator, raw_path: []const u8) PathError![]u8 {
    return path_helpers.normalizeVirtual(allocator, raw_path);
}

pub fn validateVirtualPath(path: []const u8) PathError!void {
    return path_helpers.validateVirtual(path);
}

pub fn resolveRelativeVirtualPath(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    dependency_path: []const u8,
) PathError![]u8 {
    return path_helpers.resolveRelativeVirtual(allocator, base_path, dependency_path);
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Asset {
    const normalized_path = try normalizeVirtualPath(allocator, path);
    defer allocator.free(normalized_path);

    const asset_type = detectType(normalized_path) orelse return error.UnsupportedAssetType;

    const file = try dir.openFile(io, normalized_path, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return loadFromReader(allocator, &file_reader.interface, asset_type);
}

pub fn loadFromReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    asset_type: AssetType,
) !Asset {
    switch (asset_type) {
        .mesh => return .{ .mesh = try ZMesh.read(allocator, reader) },
        .texture => return .{ .texture = try Zatex.read(allocator, reader) },
        .shader => return .{ .shader = try ZShader.read(allocator, reader) },
        .material => return .{ .material = try Zamat.read(allocator, reader) },
        .unknown => return error.UnsupportedAssetType,
    }
}

const testing = std.testing;

fn expectNormalized(input: []const u8, expected: []const u8) !void {
    const normalized = try normalizeVirtualPath(testing.allocator, input);
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings(expected, normalized);
}

test "detectType maps cooked asset extensions" {
    try testing.expectEqual(AssetType.mesh, detectType("monkey.zmesh").?);
    try testing.expectEqual(AssetType.material, detectType("monkey.zamat").?);
    try testing.expectEqual(AssetType.texture, detectType("brick_albedo.ztex").?);
    try testing.expectEqual(AssetType.shader, detectType("basic.vert.zshdr").?);
}

test "detectType requires lowercase cooked extensions" {
    try testing.expect(detectType("MONKEY.ZMESH") == null);
}

test "normalizeVirtualPath normalizes separators and leading dot segments" {
    try expectNormalized("meshes\\monkey.zmesh", "meshes/monkey.zmesh");
    try expectNormalized("./monkey.zmesh", "monkey.zmesh");
    try expectNormalized("meshes///monkey.zmesh", "meshes/monkey.zmesh");
}

test "normalizeVirtualPath rejects unsafe paths" {
    try testing.expectError(PathError.ParentTraversalNotAllowed, normalizeVirtualPath(testing.allocator, "../secret.zmesh"));
    try testing.expectError(PathError.ParentTraversalNotAllowed, normalizeVirtualPath(testing.allocator, "materials/../secret.zmesh"));
    try testing.expectError(PathError.AbsolutePathNotAllowed, normalizeVirtualPath(testing.allocator, "/tmp/file.zmesh"));
    try testing.expectError(PathError.AbsolutePathNotAllowed, normalizeVirtualPath(testing.allocator, "C:\\tmp\\file.zmesh"));
}

test "resolveRelativeVirtualPath joins sibling dependencies" {
    const resolved = try resolveRelativeVirtualPath(testing.allocator, "materials/monkey.zamat", "brick_albedo.ztex");
    defer testing.allocator.free(resolved);
    try testing.expectEqualStrings("materials/brick_albedo.ztex", resolved);
}

test "resolveRelativeVirtualPath rejects parent traversal" {
    try testing.expectError(
        PathError.ParentTraversalNotAllowed,
        resolveRelativeVirtualPath(testing.allocator, "materials/monkey.zamat", "../x.ztex"),
    );
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
    try ZMesh.write(&writer.interface, cooked);
    try writer.flush();
    file.close(testing.io);

    var asset = try loadFromFile(testing.allocator, testing.io, tmp.dir, "test.zmesh");
    defer asset.deinit(testing.allocator);

    try testing.expect(asset == .mesh);
    try testing.expectEqual(@as(u32, 3), asset.mesh.vertex_count);
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
    try ZMesh.write(&writer.interface, cooked);
    try writer.flush();
    file.close(testing.io);

    var asset = try loadFromFile(testing.allocator, testing.io, tmp.dir, "test.zmesh");
    asset.deinit(testing.allocator);
    // deinit should not crash
}
