const std = @import("std");

const cooked_mesh = @import("../../assets/cooked/mesh.zig");
const gltf_parser = @import("gltf_json_parser.zig");
const GltfJson = gltf_parser.GltfJson;
const GltfMesh = @import("mesh.zig").GltfMesh;

pub const Transform = [16]f32;

pub const identity_transform: Transform = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub const CookedModel = struct {
    allocator: std.mem.Allocator,
    parts: []Part,

    pub const Part = struct {
        mesh: cooked_mesh.CookedMesh,
        transform: Transform,
    };

    pub fn build(
        allocator: std.mem.Allocator,
        gltf: *const GltfJson,
        buffers: []const []const u8,
    ) !CookedModel {
        if (gltf.meshes.len == 0) return error.NoMeshes;

        var parts: std.ArrayList(Part) = .empty;
        errdefer {
            for (parts.items) |*part| part.mesh.deinit(allocator);
            parts.deinit(allocator);
        }

        if (gltf.nodes.len > 0) {
            const active = try allocator.alloc(bool, gltf.nodes.len);
            defer allocator.free(active);
            @memset(active, false);

            if (gltf.scenes.len > 0) {
                const scene_index: usize = @intCast(gltf.scene orelse 0);
                if (scene_index >= gltf.scenes.len) return error.SceneIndexOutOfBounds;
                for (gltf.scenes[scene_index].nodes) |node_index| {
                    try appendNode(allocator, gltf, buffers, node_index, identity_transform, active, &parts);
                }
            } else {
                const is_child = try allocator.alloc(bool, gltf.nodes.len);
                defer allocator.free(is_child);
                @memset(is_child, false);

                for (gltf.nodes) |node| {
                    for (node.children) |child| {
                        if (child >= gltf.nodes.len) return error.NodeIndexOutOfBounds;
                        is_child[child] = true;
                    }
                }

                for (is_child, 0..) |child, node_index| {
                    if (!child) {
                        try appendNode(allocator, gltf, buffers, @intCast(node_index), identity_transform, active, &parts);
                    }
                }
            }
        }

        // Some authoring/export tools emit mesh definitions without a scene
        // graph. Treat each definition as an identity-transformed model part.
        if (parts.items.len == 0) {
            for (0..gltf.meshes.len) |mesh_index| {
                try appendMesh(allocator, gltf, buffers, mesh_index, identity_transform, &parts);
            }
        }

        return .{
            .allocator = allocator,
            .parts = try parts.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *CookedModel) void {
        for (self.parts) |*part| part.mesh.deinit(self.allocator);
        self.allocator.free(self.parts);
        self.* = undefined;
    }
};

fn appendNode(
    allocator: std.mem.Allocator,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    node_index_value: u32,
    parent_transform: Transform,
    active: []bool,
    parts: *std.ArrayList(CookedModel.Part),
) !void {
    const node_index: usize = @intCast(node_index_value);
    if (node_index >= gltf.nodes.len) return error.NodeIndexOutOfBounds;
    if (active[node_index]) return error.NodeCycle;

    active[node_index] = true;
    defer active[node_index] = false;

    const node = gltf.nodes[node_index];
    const transform = multiply(nodeTransform(node), parent_transform);

    if (node.mesh) |mesh_index| {
        try appendMesh(allocator, gltf, buffers, mesh_index, transform, parts);
    }
    for (node.children) |child| {
        try appendNode(allocator, gltf, buffers, child, transform, active, parts);
    }
}

fn appendMesh(
    allocator: std.mem.Allocator,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    mesh_index_value: anytype,
    transform: Transform,
    parts: *std.ArrayList(CookedModel.Part),
) !void {
    const mesh_index: usize = @intCast(mesh_index_value);
    if (mesh_index >= gltf.meshes.len) return error.MeshIndexOutOfBounds;

    var parsed = try GltfMesh.buildMesh(allocator, gltf, mesh_index, buffers);
    defer parsed.deinit();

    var cooked = try cooked_mesh.CookedMesh.cook(allocator, &parsed.raw);
    errdefer cooked.deinit(allocator);
    try parts.append(allocator, .{ .mesh = cooked, .transform = transform });
}

fn nodeTransform(node: gltf_parser.GltfNode) Transform {
    if (node.matrix) |matrix| return matrix;

    const q_len = @sqrt(
        node.rotation[0] * node.rotation[0] +
            node.rotation[1] * node.rotation[1] +
            node.rotation[2] * node.rotation[2] +
            node.rotation[3] * node.rotation[3],
    );
    const q = if (q_len > 0.000001)
        [4]f32{
            node.rotation[0] / q_len,
            node.rotation[1] / q_len,
            node.rotation[2] / q_len,
            node.rotation[3] / q_len,
        }
    else
        [4]f32{ 0, 0, 0, 1 };

    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const rotation: Transform = .{
        1 - 2 * (y * y + z * z), 2 * (x * y + w * z),     2 * (x * z - w * y),     0,
        2 * (x * y - w * z),     1 - 2 * (x * x + z * z), 2 * (y * z + w * x),     0,
        2 * (x * z + w * y),     2 * (y * z - w * x),     1 - 2 * (x * x + y * y), 0,
        0,                       0,                       0,                       1,
    };
    const scale: Transform = .{
        node.scale[0], 0,             0,             0,
        0,             node.scale[1], 0,             0,
        0,             0,             node.scale[2], 0,
        0,             0,             0,             1,
    };
    const translation: Transform = .{
        1,                   0,                   0,                   0,
        0,                   1,                   0,                   0,
        0,                   0,                   1,                   0,
        node.translation[0], node.translation[1], node.translation[2], 1,
    };
    return multiply(multiply(scale, rotation), translation);
}

fn multiply(a: Transform, b: Transform) Transform {
    var result: Transform = undefined;
    for (0..4) |row| {
        for (0..4) |column| {
            var value: f32 = 0;
            for (0..4) |i| value += a[row * 4 + i] * b[i * 4 + column];
            result[row * 4 + column] = value;
        }
    }
    return result;
}

const testing = std.testing;

test "nodeTransform preserves translation in row-vector layout" {
    const transform = nodeTransform(.{ .translation = .{ 2, 3, 4 } });
    try testing.expectEqual(@as(f32, 2), transform[12]);
    try testing.expectEqual(@as(f32, 3), transform[13]);
    try testing.expectEqual(@as(f32, 4), transform[14]);
}

test "child transform is composed before its parent" {
    const parent = nodeTransform(.{ .translation = .{ 2, 0, 0 } });
    const child = nodeTransform(.{ .translation = .{ 0, 3, 0 } });
    const world = multiply(child, parent);
    try testing.expectEqual(@as(f32, 2), world[12]);
    try testing.expectEqual(@as(f32, 3), world[13]);
}

test "CookedModel builds every mesh node with its scene transform" {
    const positions = [_][3]f32{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
    };
    const indices = [_]u16{ 0, 1, 2 };
    var bin: [@sizeOf(@TypeOf(positions)) + @sizeOf(@TypeOf(indices))]u8 = undefined;
    @memcpy(bin[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    @memcpy(bin[@sizeOf(@TypeOf(positions))..], std.mem.asBytes(&indices));

    var buffer_views = [_]gltf_parser.GltfBufferView{
        .{ .buffer = 0, .byteOffset = 0, .byteLength = @sizeOf(@TypeOf(positions)) },
        .{ .buffer = 0, .byteOffset = @sizeOf(@TypeOf(positions)), .byteLength = @sizeOf(@TypeOf(indices)) },
    };
    var accessors = [_]gltf_parser.GltfAccessor{
        .{ .bufferView = 0, .componentType = .FLOAT, .count = 3, .type = .VEC3 },
        .{ .bufferView = 1, .componentType = .UNSIGNED_SHORT, .count = 3, .type = .SCALAR },
    };
    var left_primitives = [_]gltf_parser.GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var right_primitives = left_primitives;
    var meshes = [_]gltf_parser.GltfMesh{
        .{ .name = "Left", .primitives = &left_primitives },
        .{ .name = "Right", .primitives = &right_primitives },
    };
    var nodes = [_]gltf_parser.GltfNode{
        .{ .mesh = 0, .translation = .{ -2, 0, 0 } },
        .{ .mesh = 1, .translation = .{ 2, 0, 0 } },
    };
    var scene_nodes = [_]u32{ 0, 1 };
    var scenes = [_]gltf_parser.GltfScene{.{ .nodes = &scene_nodes }};
    var buffers = [_][]const u8{&bin};
    const gltf: GltfJson = .{
        .scene = 0,
        .scenes = &scenes,
        .nodes = &nodes,
        .meshes = &meshes,
        .accessors = &accessors,
        .bufferViews = &buffer_views,
    };

    var model = try CookedModel.build(testing.allocator, &gltf, &buffers);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.parts.len);
    try testing.expectEqual(@as(f32, -2), model.parts[0].transform[12]);
    try testing.expectEqual(@as(f32, 2), model.parts[1].transform[12]);
    try testing.expectEqual(@as(usize, 3), model.parts[0].mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), model.parts[1].mesh.vertices.len);
}
