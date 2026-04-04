const std = @import("std");
const mesh = @import("../assets/mesh.zig");
const gltf_parser = @import("gltf_json_parser.zig");
const GltfJson = gltf_parser.GltfJson;
const GltfBufferView = gltf_parser.GltfBufferView;
const GltfAccessor = gltf_parser.GltfAccessor;

pub const BuildMeshError = error{
    MissingPositionAttribute,
    OutOfBounds,
    OutOfMemory,
};

pub const GltfMesh = struct {
    allocator: std.mem.Allocator,
    raw: mesh.RawMesh,

    pub fn buildMesh(allocator: std.mem.Allocator, gltf: *const GltfJson, mesh_index: usize, bin: []const u8) BuildMeshError!GltfMesh {
        const json_mesh = gltf.meshes[mesh_index];

        var vertex_count: u32 = 0;
        for (json_mesh.primitives) |prim| {
            const pos_index = prim.attributes.POSITION orelse return BuildMeshError.MissingPositionAttribute;
            vertex_count += gltf.accessors[pos_index].count;
        }

        const vertices = try allocator.alloc(mesh.RawVertex, vertex_count);
        errdefer allocator.free(vertices);

        var vertex_offset: u32 = 0;
        for (json_mesh.primitives) |prim| {
            const pos_index = prim.attributes.POSITION.?;
            const pos_accessor = &gltf.accessors[pos_index];
            const positions = try pos_accessor.readAccessorTy([3]f32, allocator, gltf.bufferViews, bin);

            const normals = if (prim.attributes.NORMAL) |idx|
                try gltf.accessors[idx].readAccessorTy([3]f32, allocator, gltf.bufferViews, bin)
            else
                null;

            const tangents = if (prim.attributes.TANGENT) |idx|
                try gltf.accessors[idx].readAccessorTy([4]f32, allocator, gltf.bufferViews, bin)
            else
                null;

            const uv0s = if (prim.attributes.TEXCOORD_0) |idx|
                try gltf.accessors[idx].readAccessorTy([2]f32, allocator, gltf.bufferViews, bin)
            else
                null;

            const uv1s = if (prim.attributes.TEXCOORD_1) |idx|
                try gltf.accessors[idx].readAccessorTy([2]f32, allocator, gltf.bufferViews, bin)
            else
                null;

            const joints = if (prim.attributes.JOINTS_0) |idx|
                try gltf.accessors[idx].readAccessorTy([4]u16, allocator, gltf.bufferViews, bin)
            else
                null;

            const weights = if (prim.attributes.WEIGHTS_0) |idx|
                try gltf.accessors[idx].readAccessorTy([4]f32, allocator, gltf.bufferViews, bin)
            else
                null;

            for (0..pos_accessor.count) |i| {
                vertices[vertex_offset + i] = .{
                    .position = positions[i],
                    .normal = if (normals) |n| n[i] else null,
                    .tangest = if (tangents) |t| t[i] else null,
                    .uv0 = if (uv0s) |u| u[i] else null,
                    .uv1 = if (uv1s) |u| u[i] else null,
                    .joint_indices = if (joints) |j| j[i] else null,
                    .joint_weights = if (weights) |w| w[i] else null,
                };
            }

            vertex_offset += pos_accessor.count;
        }

        return .{
            .allocator = allocator,
            .raw = .{
                .vertices = vertices,
                .indices = &.{},
                .submeshes = &.{},
                .name = json_mesh.name,
            },
        };
    }

    pub fn deinit(self: *GltfMesh) void {
        self.allocator.free(self.raw.vertices);
        if (self.raw.indices.len > 0) {
            self.allocator.free(self.raw.indices);
        }
        if (self.raw.submeshes.len > 0) {
            self.allocator.free(self.raw.submeshes);
        }
        self.* = undefined;
    }
};
