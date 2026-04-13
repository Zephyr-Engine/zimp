const std = @import("std");
const mesh = @import("../../assets/raw/mesh.zig");
const gltf_parser = @import("gltf_json_parser.zig");
const CookedMesh = @import("../../assets/cooked/mesh.zig").CookedMesh;
const GltfJson = gltf_parser.GltfJson;
const GltfBufferView = gltf_parser.GltfBufferView;
const GltfAccessor = gltf_parser.GltfAccessor;
const GltfPrimitive = gltf_parser.GltfPrimitive;

pub const BuildMeshError = error{
    MissingPositionAttribute,
    UnsupportedPrimitiveMode,
    InvalidIndexCount,
    OutOfBounds,
    OutOfMemory,
};

pub const GltfMesh = struct {
    allocator: std.mem.Allocator,
    raw: mesh.RawMesh,

    pub fn cook(self: *GltfMesh, allocator: std.mem.Allocator) !CookedMesh {
        return CookedMesh.cook(allocator, &self.raw);
    }

    pub fn buildMesh(allocator: std.mem.Allocator, gltf: *const GltfJson, mesh_index: usize, bin: []const u8) BuildMeshError!GltfMesh {
        const json_mesh = gltf.meshes[mesh_index];
        const primitives = json_mesh.primitives;

        var vertex_count: u32 = 0;
        var index_count: u32 = 0;
        for (primitives) |prim| {
            if (prim.mode != 4) {
                return BuildMeshError.UnsupportedPrimitiveMode;
            }

            const pos_index = prim.attributes.POSITION orelse return BuildMeshError.MissingPositionAttribute;
            vertex_count += gltf.accessors[pos_index].count;
            if (prim.indices) |idx| {
                const count = gltf.accessors[idx].count;
                if (count % 3 != 0) {
                    return BuildMeshError.InvalidIndexCount;
                }

                index_count += count;
            }
        }

        const vertices = try allocator.alloc(mesh.RawVertex, vertex_count);
        errdefer allocator.free(vertices);

        const indices = if (index_count > 0) try allocator.alloc(u32, index_count) else @as([]u32, &.{});
        errdefer if (index_count > 0) allocator.free(indices);

        const submeshes = try allocator.alloc(mesh.RawSubmesh, primitives.len);
        errdefer allocator.free(submeshes);

        var vertex_offset: u32 = 0;
        var index_offset: u32 = 0;
        for (primitives, 0..) |prim, prim_idx| {
            const count = try processVertices(allocator, gltf, bin, prim, vertices, vertex_offset);
            try processIndices(allocator, gltf, bin, prim, indices, index_offset, vertex_offset);

            const prim_index_count: u32 = if (prim.indices) |idx| gltf.accessors[idx].count else 0;
            submeshes[prim_idx] = .{
                .index_offset = index_offset,
                .index_count = prim_index_count,
                .material_index = @intCast(prim.material orelse 0),
            };

            index_offset += prim_index_count;
            vertex_offset += count;
        }

        return .{
            .allocator = allocator,
            .raw = .{
                .vertices = vertices,
                .indices = indices,
                .submeshes = submeshes,
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
            .tangent = optionalIndex(tangents, i),
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

const testing = std.testing;
const AccessorComponentType = gltf_parser.AccessorComponentType;
const AccessorType = gltf_parser.AccessorType;
const GltfAttributes = gltf_parser.GltfAttributes;

fn toBytes(comptime T: type, comptime data: []const T) *const [@sizeOf(T) * data.len]u8 {
    return @ptrCast(data);
}

// Triangle: 3 vertices with positions only, 3 u16 indices
const triangle_positions = [_][3]f32{
    .{ 0.0, 0.0, 0.0 },
    .{ 1.0, 0.0, 0.0 },
    .{ 0.5, 1.0, 0.0 },
};
const triangle_indices_u16 = [_]u16{ 0, 1, 2 };
const triangle_normals = [_][3]f32{
    .{ 0.0, 0.0, 1.0 },
    .{ 0.0, 0.0, 1.0 },
    .{ 0.0, 0.0, 1.0 },
};
const triangle_uvs = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 1.0, 0.0 },
    .{ 0.5, 1.0 },
};

// Binary layout: [positions (36)][indices_u16 (6)][normals (36)][uvs (24)]
const triangle_bin = toBytes([3]f32, &triangle_positions) ++
    toBytes(u16, &triangle_indices_u16) ++
    toBytes([3]f32, &triangle_normals) ++
    toBytes([2]f32, &triangle_uvs);

const triangle_buffer_views = [_]GltfBufferView{
    .{ .buffer = 0, .byteOffset = 0, .byteLength = 36 }, // positions: 3 * 12
    .{ .buffer = 0, .byteOffset = 36, .byteLength = 6 }, // indices: 3 * 2
    .{ .buffer = 0, .byteOffset = 42, .byteLength = 36 }, // normals: 3 * 12
    .{ .buffer = 0, .byteOffset = 78, .byteLength = 24 }, // uvs: 3 * 8
};

const triangle_accessors = [_]GltfAccessor{
    .{ .bufferView = 0, .componentType = .FLOAT, .count = 3, .type = .VEC3 }, // 0: positions
    .{ .bufferView = 1, .componentType = .UNSIGNED_SHORT, .count = 3, .type = .SCALAR }, // 1: indices
    .{ .bufferView = 2, .componentType = .FLOAT, .count = 3, .type = .VEC3 }, // 2: normals
    .{ .bufferView = 3, .componentType = .FLOAT, .count = 3, .type = .VEC2 }, // 3: uvs
};

test "build triangle with positions only" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .name = "Triangle",
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual(3, result.raw.vertices.len);
    try testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, result.raw.vertices[0].position);
    try testing.expectEqual([3]f32{ 1.0, 0.0, 0.0 }, result.raw.vertices[1].position);
    try testing.expectEqual([3]f32{ 0.5, 1.0, 0.0 }, result.raw.vertices[2].position);

    // No normals/uvs on this primitive
    try testing.expectEqual(null, result.raw.vertices[0].normal);
    try testing.expectEqual(null, result.raw.vertices[0].uv0);

    try testing.expectEqual(3, result.raw.indices.len);
    try testing.expectEqual(0, result.raw.indices[0]);
    try testing.expectEqual(1, result.raw.indices[1]);
    try testing.expectEqual(2, result.raw.indices[2]);
}

test "build triangle with normals and uvs" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0, .NORMAL = 2, .TEXCOORD_0 = 3 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .name = "TriangleWithAttrs",
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual([3]f32{ 0.0, 0.0, 1.0 }, result.raw.vertices[0].normal.?);
    try testing.expectEqual([3]f32{ 0.0, 0.0, 1.0 }, result.raw.vertices[2].normal.?);
    try testing.expectEqual([2]f32{ 0.0, 0.0 }, result.raw.vertices[0].uv0.?);
    try testing.expectEqual([2]f32{ 0.5, 1.0 }, result.raw.vertices[2].uv0.?);
    try testing.expectEqual(null, result.raw.vertices[0].uv1);
    try testing.expectEqual(null, result.raw.vertices[0].tangent);
}

test "build mesh without indices" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual(3, result.raw.vertices.len);
    try testing.expectEqual(0, result.raw.indices.len);
}

test "submesh is populated correctly" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
        .material = 2,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .name = "Sub",
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual(1, result.raw.submeshes.len);
    try testing.expectEqual(0, result.raw.submeshes[0].index_offset);
    try testing.expectEqual(3, result.raw.submeshes[0].index_count);
    try testing.expectEqual(2, result.raw.submeshes[0].material_index);
}

test "submesh defaults material to 0" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual(0, result.raw.submeshes[0].material_index);
}

test "multi-primitive mesh rebases indices" {
    // Two primitives each using the same 3 positions but different indices
    // Primitive 0 uses accessors 0 (pos) and 1 (idx)
    // Primitive 1 uses accessors 0 (pos) and 1 (idx)
    // After merging, prim 1's indices should be offset by 3
    var primitives = [_]GltfPrimitive{
        .{ .attributes = .{ .POSITION = 0 }, .indices = 1, .material = 0 },
        .{ .attributes = .{ .POSITION = 0 }, .indices = 1, .material = 1 },
    };
    var meshes = [_]gltf_parser.GltfMesh{.{
        .name = "Multi",
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual(6, result.raw.vertices.len);
    try testing.expectEqual(6, result.raw.indices.len);

    // First primitive indices: 0, 1, 2 (no offset)
    try testing.expectEqual(0, result.raw.indices[0]);
    try testing.expectEqual(1, result.raw.indices[1]);
    try testing.expectEqual(2, result.raw.indices[2]);

    // Second primitive indices: 3, 4, 5 (offset by 3)
    try testing.expectEqual(3, result.raw.indices[3]);
    try testing.expectEqual(4, result.raw.indices[4]);
    try testing.expectEqual(5, result.raw.indices[5]);

    // Two submeshes
    try testing.expectEqual(2, result.raw.submeshes.len);
    try testing.expectEqual(0, result.raw.submeshes[0].index_offset);
    try testing.expectEqual(3, result.raw.submeshes[0].index_count);
    try testing.expectEqual(0, result.raw.submeshes[0].material_index);
    try testing.expectEqual(3, result.raw.submeshes[1].index_offset);
    try testing.expectEqual(3, result.raw.submeshes[1].index_count);
    try testing.expectEqual(1, result.raw.submeshes[1].material_index);
}

test "u32 index type" {
    const indices_u32 = [_]u32{ 0, 1, 2 };
    const bin_u32 = toBytes([3]f32, &triangle_positions) ++ toBytes(u32, &indices_u32);

    var bvs = [_]GltfBufferView{
        .{ .buffer = 0, .byteOffset = 0, .byteLength = 36 },
        .{ .buffer = 0, .byteOffset = 36, .byteLength = 12 },
    };
    var accs = [_]GltfAccessor{
        .{ .bufferView = 0, .componentType = .FLOAT, .count = 3, .type = .VEC3 },
        .{ .bufferView = 1, .componentType = .UNSIGNED_INT, .count = 3, .type = .SCALAR },
    };
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{ .primitives = &primitives }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = &accs,
        .bufferViews = &bvs,
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, bin_u32);
    defer result.deinit();

    try testing.expectEqual(3, result.raw.indices.len);
    try testing.expectEqual(0, result.raw.indices[0]);
    try testing.expectEqual(2, result.raw.indices[2]);
}

test "u8 index type" {
    const indices_u8 = [_]u8{ 0, 1, 2 };
    const bin_u8 = toBytes([3]f32, &triangle_positions) ++ toBytes(u8, &indices_u8);

    var bvs = [_]GltfBufferView{
        .{ .buffer = 0, .byteOffset = 0, .byteLength = 36 },
        .{ .buffer = 0, .byteOffset = 36, .byteLength = 3 },
    };
    var accs = [_]GltfAccessor{
        .{ .bufferView = 0, .componentType = .FLOAT, .count = 3, .type = .VEC3 },
        .{ .bufferView = 1, .componentType = .UNSIGNED_BYTE, .count = 3, .type = .SCALAR },
    };
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{ .primitives = &primitives }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = &accs,
        .bufferViews = &bvs,
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, bin_u8);
    defer result.deinit();

    try testing.expectEqual(3, result.raw.indices.len);
    try testing.expectEqual(0, result.raw.indices[0]);
    try testing.expectEqual(2, result.raw.indices[2]);
}

test "error on missing position attribute" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{},
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{ .primitives = &primitives }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    try testing.expectError(BuildMeshError.MissingPositionAttribute, GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin));
}

test "error on unsupported primitive mode" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .mode = 1, // LINES
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{ .primitives = &primitives }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    try testing.expectError(BuildMeshError.UnsupportedPrimitiveMode, GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin));
}

test "error on invalid index count" {
    // 2 indices is not divisible by 3
    const indices_bad = [_]u16{ 0, 1 };
    const bin_bad = toBytes([3]f32, &triangle_positions) ++ toBytes(u16, &indices_bad);

    var bvs = [_]GltfBufferView{
        .{ .buffer = 0, .byteOffset = 0, .byteLength = 36 },
        .{ .buffer = 0, .byteOffset = 36, .byteLength = 4 },
    };
    var accs = [_]GltfAccessor{
        .{ .bufferView = 0, .componentType = .FLOAT, .count = 3, .type = .VEC3 },
        .{ .bufferView = 1, .componentType = .UNSIGNED_SHORT, .count = 2, .type = .SCALAR },
    };
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{ .primitives = &primitives }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = &accs,
        .bufferViews = &bvs,
    };

    try testing.expectError(BuildMeshError.InvalidIndexCount, GltfMesh.buildMesh(testing.allocator, &gltf, 0, bin_bad));
}

test "mesh name is preserved" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .name = "MyMesh",
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqualStrings("MyMesh", result.raw.name.?);
}

test "mesh name null when absent" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    defer result.deinit();

    try testing.expectEqual(null, result.raw.name);
}

test "deinit frees all memory" {
    var primitives = [_]GltfPrimitive{.{
        .attributes = .{ .POSITION = 0 },
        .indices = 1,
    }};
    var meshes = [_]gltf_parser.GltfMesh{.{
        .primitives = &primitives,
    }};
    const gltf = GltfJson{
        .meshes = &meshes,
        .accessors = @constCast(&triangle_accessors),
        .bufferViews = @constCast(&triangle_buffer_views),
    };

    var result = try GltfMesh.buildMesh(testing.allocator, &gltf, 0, triangle_bin);
    result.deinit();
    // testing.allocator will detect leaks if deinit missed anything
}
