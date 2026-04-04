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

            const normals = try readAttr([3]f32, prim.attributes.NORMAL, allocator, gltf, bin);
            const tangents = try readAttr([4]f32, prim.attributes.TANGENT, allocator, gltf, bin);
            const uv0s = try readAttr([2]f32, prim.attributes.TEXCOORD_0, allocator, gltf, bin);
            const uv1s = try readAttr([2]f32, prim.attributes.TEXCOORD_1, allocator, gltf, bin);
            const joints = try readAttr([4]u16, prim.attributes.JOINTS_0, allocator, gltf, bin);
            const weights = try readAttr([4]f32, prim.attributes.WEIGHTS_0, allocator, gltf, bin);

            for (0..pos_accessor.count) |i| {
                vertices[vertex_offset + i] = .{
                    .position = positions[i],
                    .normal = optionalIndex(normals, i),
                    .tangest = optionalIndex(tangents, i),
                    .uv0 = optionalIndex(uv0s, i),
                    .uv1 = optionalIndex(uv1s, i),
                    .joint_indices = optionalIndex(joints, i),
                    .joint_weights = optionalIndex(weights, i),
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

fn readAttr(comptime T: type, attr_index: ?u32, allocator: std.mem.Allocator, gltf: *const GltfJson, bin: []const u8) BuildMeshError!?[]align(1) const T {
    const idx = attr_index orelse return null;
    return try gltf.accessors[idx].readAccessorTy(T, allocator, gltf.bufferViews, bin);
}

fn optionalIndex(slice: anytype, i: usize) ?std.meta.Elem(@TypeOf(slice.?)) {
    return if (slice) |s| s[i] else null;
}
