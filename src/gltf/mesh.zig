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
            const pos_bytes = try pos_accessor.readAccessor(allocator, gltf.bufferViews, bin);
            const positions = std.mem.bytesAsSlice([3]f32, pos_bytes);

            for (0..pos_accessor.count) |i| {
                vertices[vertex_offset + i] = .{
                    .position = positions[i],
                    .normal = null,
                    .tangest = null,
                    .uv0 = null,
                    .uv1 = null,
                    .joint_indices = null,
                    .joint_weights = null,
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
        if (self.raw.indices.len > 0) self.allocator.free(self.raw.indices);
        if (self.raw.submeshes.len > 0) self.allocator.free(self.raw.submeshes);
        self.* = undefined;
    }
};
