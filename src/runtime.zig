const std = @import("std");
const ZMesh = @import("formats/zmesh.zig").ZMesh;
const Zatex = @import("formats/ztex.zig").Zatex;
const ZShader = @import("formats/zshdr.zig").ZShader;
const Zamat = @import("formats/zamat.zig").Zamat;
const constants = @import("shared/constants.zig");
const file_read = @import("shared/file_read.zig");

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

const AssetType = enum { mesh, texture, shader, material };

fn detectType(path: []const u8) ?AssetType {
    if (std.mem.endsWith(u8, path, ".zmesh")) return .mesh;
    if (std.mem.endsWith(u8, path, ".ztex")) return .texture;
    if (std.mem.endsWith(u8, path, ".zshdr")) return .shader;
    if (std.mem.endsWith(u8, path, ".zamat")) return .material;
    return null;
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Asset {
    const asset_type = detectType(path) orelse return error.UnsupportedAssetType;

    switch (asset_type) {
        .mesh => {
            const file = try dir.openFile(io, path, .{});
            defer file.close(io);
            return Asset{ .mesh = try ZMesh.read(allocator, io, file) };
        },
        .texture => {
            const file = try dir.openFile(io, path, .{});
            defer file.close(io);
            return Asset{ .texture = try Zatex.read(allocator, io, file) };
        },
        .shader => {
            const result = try file_read.readFileAllocChunked(allocator, io, dir, path, .{});
            defer allocator.free(result.bytes);
            var reader = std.Io.Reader.fixed(result.bytes);
            return Asset{ .shader = try ZShader.read(allocator, &reader) };
        },
        .material => {
            const result = try file_read.readFileAllocChunked(allocator, io, dir, path, .{});
            defer allocator.free(result.bytes);
            var reader = std.Io.Reader.fixed(result.bytes);
            return Asset{ .material = try Zamat.read(allocator, &reader) };
        },
    }
}

const testing = std.testing;

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
