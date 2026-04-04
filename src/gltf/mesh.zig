const std = @import("std");
const mesh = @import("../assets/mesh.zig");
const gltf_parser = @import("gltf_json_parser.zig");
const GltfJson = gltf_parser.GltfJson;
const GltfBufferView = gltf_parser.GltfBufferView;
const GltfAccessor = gltf_parser.GltfAccessor;
const GltfPrimitive = gltf_parser.GltfPrimitive;

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
        const primitives = json_mesh.primitives;

        var vertex_count: u32 = 0;
        var index_count: u32 = 0;
        for (primitives) |prim| {
            const pos_index = prim.attributes.POSITION orelse return BuildMeshError.MissingPositionAttribute;
            vertex_count += gltf.accessors[pos_index].count;
            if (prim.indices) |idx| {
                index_count += gltf.accessors[idx].count;
            }
        }

        const vertices = try allocator.alloc(mesh.RawVertex, vertex_count);
        errdefer allocator.free(vertices);

        const indices = if (index_count > 0) try allocator.alloc(u32, index_count) else @as([]u32, &.{});
        errdefer if (index_count > 0) allocator.free(indices);

        var vertex_offset: u32 = 0;
        var index_offset: u32 = 0;
        for (primitives) |prim| {
            const count = try processVertices(allocator, gltf, bin, prim, vertices, vertex_offset);
            try processIndices(allocator, gltf, bin, prim, indices, index_offset, vertex_offset);
            if (prim.indices) |idx| {
                index_offset += gltf.accessors[idx].count;
            }
            vertex_offset += count;
        }

        return .{
            .allocator = allocator,
            .raw = .{
                .vertices = vertices,
                .indices = indices,
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

fn processVertices(allocator: std.mem.Allocator, gltf: *const GltfJson, bin: []const u8, prim: GltfPrimitive, vertices: []mesh.RawVertex, offset: u32) BuildMeshError!u32 {
    const pos_accessor = &gltf.accessors[prim.attributes.POSITION.?];
    const positions = try pos_accessor.readAccessorSlice([3]f32, allocator, gltf.bufferViews, bin);

    const normals = try readAttr([3]f32, prim.attributes.NORMAL, allocator, gltf, bin);
    const tangents = try readAttr([4]f32, prim.attributes.TANGENT, allocator, gltf, bin);
    const uv0s = try readAttr([2]f32, prim.attributes.TEXCOORD_0, allocator, gltf, bin);
    const uv1s = try readAttr([2]f32, prim.attributes.TEXCOORD_1, allocator, gltf, bin);
    const joints = try readAttr([4]u16, prim.attributes.JOINTS_0, allocator, gltf, bin);
    const weights = try readAttr([4]f32, prim.attributes.WEIGHTS_0, allocator, gltf, bin);

    for (0..pos_accessor.count) |i| {
        vertices[offset + i] = .{
            .position = positions[i],
            .normal = optionalIndex(normals, i),
            .tangest = optionalIndex(tangents, i),
            .uv0 = optionalIndex(uv0s, i),
            .uv1 = optionalIndex(uv1s, i),
            .joint_indices = optionalIndex(joints, i),
            .joint_weights = optionalIndex(weights, i),
        };
    }

    return pos_accessor.count;
}

fn processIndices(allocator: std.mem.Allocator, gltf: *const GltfJson, bin: []const u8, prim: GltfPrimitive, indices: []u32, offset: u32, vertex_offset: u32) BuildMeshError!void {
    const indices_index = prim.indices orelse return;
    const idx_accessor = &gltf.accessors[indices_index];
    const idx_bytes = try idx_accessor.readAccessor(allocator, gltf.bufferViews, bin);

    switch (idx_accessor.componentType) {
        .UNSIGNED_BYTE => {
            for (idx_bytes, 0..) |b, j| {
                indices[offset + j] = @as(u32, b) + vertex_offset;
            }
        },
        .UNSIGNED_SHORT => {
            const shorts = std.mem.bytesAsSlice(u16, idx_bytes);
            for (shorts, 0..) |s, j| {
                indices[offset + j] = @as(u32, s) + vertex_offset;
            }
        },
        .UNSIGNED_INT => {
            const ints = std.mem.bytesAsSlice(u32, idx_bytes);
            for (ints, 0..) |v, j| {
                indices[offset + j] = v + vertex_offset;
            }
        },
        else => return BuildMeshError.OutOfBounds,
    }
}

fn readAttr(comptime T: type, attr_index: ?u32, allocator: std.mem.Allocator, gltf: *const GltfJson, bin: []const u8) BuildMeshError!?[]align(1) const T {
    const idx = attr_index orelse return null;
    return try gltf.accessors[idx].readAccessorSlice(T, allocator, gltf.bufferViews, bin);
}

fn optionalIndex(slice: anytype, i: usize) ?std.meta.Elem(@TypeOf(slice.?)) {
    return if (slice) |s| s[i] else null;
}
