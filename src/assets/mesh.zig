const std = @import("std");
const logger = @import("../logger.zig").logger;
const Map = std.AutoHashMap(u64, u32);
const ReMap = std.AutoHashMap(u32, u32);

pub const RawVertex = struct {
    position: [3]f32,
    normal: ?[3]f32,
    tangest: ?[4]f32,
    uv0: ?[2]f32,
    uv1: ?[2]f32,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f32,

    pub fn hash(self: *const RawVertex) u64 {
        return std.hash.XxHash64.hash(0, std.mem.asBytes(self));
    }
};

pub const RawSubmesh = struct {
    index_offset: u32,
    index_count: u32,
    material_index: u16,
};

pub const RawMesh = struct {
    vertices: []RawVertex,
    indices: []u32,
    submeshes: []RawSubmesh,
    name: ?[]const u8,

    pub fn deduplicateVertices(self: *RawMesh, allocator: std.mem.Allocator) !void {
        logger.debug("[Optimizing Mesh] Step 1: Deduplicating Vertices", .{});

        var deduped: std.ArrayList(RawVertex) = try .initCapacity(allocator, self.vertices.len);
        defer deduped.deinit(allocator);

        // hash → index in deduped array
        var map = Map.init(allocator);
        defer map.deinit();

        // old vertex index → new vertex index
        var remap = ReMap.init(allocator);
        defer remap.deinit();

        for (0.., self.vertices) |i, vertex| {
            const h = vertex.hash();
            const existing = map.get(h);

            if (existing) |existing_idx| {
                if (std.mem.eql(u8, std.mem.asBytes(&deduped.items[existing_idx]), std.mem.asBytes(&vertex))) {
                    try remap.put(@intCast(i), existing_idx);
                    continue;
                }
                logger.warn("[Mesh Optimize] Hash collision detected at vertex {d}", .{i});
            }

            const new_idx: u32 = @intCast(deduped.items.len);
            deduped.appendAssumeCapacity(vertex);

            if (existing == null) {
                try map.put(h, new_idx);
            }
            try remap.put(@intCast(i), new_idx);
        }

        // No duplicates found, nothing to do
        if (deduped.items.len == self.vertices.len) {
            return;
        }

        const original_len = self.vertices.len;

        // Rewrite index buffer using the remap table
        for (self.indices) |*index| {
            index.* = remap.get(index.*).?;
        }

        // Replace vertices with deduplicated array
        allocator.free(self.vertices);
        self.vertices = try allocator.dupe(RawVertex, deduped.items);

        logger.debug("[Optimizing Mesh] Deduplicated {d} -> {d} vertices", .{ original_len, self.vertices.len });
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

fn makeVertex(x: f32, y: f32, z: f32) RawVertex {
    return .{
        .position = .{ x, y, z },
        .normal = null,
        .tangest = null,
        .uv0 = null,
        .uv1 = null,
        .joint_indices = null,
        .joint_weights = null,
    };
}

/// Resolve an index triple to actual vertex positions for comparison.
fn resolveTriangle(vertices: []const RawVertex, indices: []const u32, tri_start: usize) [3][3]f32 {
    return .{
        vertices[indices[tri_start + 0]].position,
        vertices[indices[tri_start + 1]].position,
        vertices[indices[tri_start + 2]].position,
    };
}

test "quad with shared edge deduplicates from 6 to 4 vertices" {
    const allocator = std.testing.allocator;

    // Quad: two triangles sharing edge v1-v2
    //   v0 --- v1
    //   |  \    |
    //   |   \   |
    //   v2 --- v3
    //
    // Triangle A: v0, v1, v2
    // Triangle B: v1, v3, v2  (duplicates v1 and v2)

    const v0 = makeVertex(0, 1, 0);
    const v1 = makeVertex(1, 1, 0);
    const v2 = makeVertex(0, 0, 0);
    const v3 = makeVertex(1, 0, 0);

    const vertices = try allocator.dupe(RawVertex, &.{ v0, v1, v2, v1, v3, v2 });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.deduplicateVertices(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.len);
}

test "mesh with no duplicates is unchanged" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(0, 1, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.deduplicateVertices(allocator);
    // Early-return path: original slices are still owned by us
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    // Indices should be untouched
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, mesh.indices);
}

test "all remapped indices are valid" {
    const allocator = std.testing.allocator;

    // 4 triangles, heavy duplication
    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0), // 0
        makeVertex(1, 0, 0), // 1
        makeVertex(0, 1, 0), // 2
        makeVertex(1, 0, 0), // 3 = dup of 1
        makeVertex(0, 1, 0), // 4 = dup of 2
        makeVertex(1, 1, 0), // 5
        makeVertex(0, 0, 0), // 6 = dup of 0
        makeVertex(1, 1, 0), // 7 = dup of 5
        makeVertex(0, 1, 0), // 8 = dup of 2
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.deduplicateVertices(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    for (mesh.indices) |index| {
        try std.testing.expect(index < mesh.vertices.len);
    }
}

test "dedup preserves rendered triangles" {
    const allocator = std.testing.allocator;

    const v0 = makeVertex(0, 1, 0);
    const v1 = makeVertex(1, 1, 0);
    const v2 = makeVertex(0, 0, 0);
    const v3 = makeVertex(1, 0, 0);

    // Two triangles with duplicated vertices on the shared edge
    const original_verts = [_]RawVertex{ v0, v1, v2, v1, v3, v2 };
    const original_indices = [_]u32{ 0, 1, 2, 3, 4, 5 };

    // Capture the triangles before dedup (resolved to positions)
    const tri0_before = resolveTriangle(&original_verts, &original_indices, 0);
    const tri1_before = resolveTriangle(&original_verts, &original_indices, 3);

    const vertices = try allocator.dupe(RawVertex, &original_verts);
    const indices = try allocator.dupe(u32, &original_indices);

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.deduplicateVertices(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    // Resolve triangles after dedup — should produce the same geometry
    const tri0_after = resolveTriangle(mesh.vertices, mesh.indices, 0);
    const tri1_after = resolveTriangle(mesh.vertices, mesh.indices, 3);

    try std.testing.expectEqualDeep(tri0_before, tri0_after);
    try std.testing.expectEqualDeep(tri1_before, tri1_after);
}

test "all vertices identical deduplicates to one" {
    const allocator = std.testing.allocator;

    const v = makeVertex(1, 2, 3);
    const vertices = try allocator.dupe(RawVertex, &.{ v, v, v, v, v });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 0 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.deduplicateVertices(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 1), mesh.vertices.len);
    // Every index should now point to 0
    for (mesh.indices) |index| {
        try std.testing.expectEqual(@as(u32, 0), index);
    }
}

test "vertices differing only in optional fields are not deduplicated" {
    const allocator = std.testing.allocator;

    var v_with_normal = makeVertex(1, 0, 0);
    v_with_normal.normal = .{ 0, 1, 0 };

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(1, 0, 0), // no normal
        v_with_normal, // has normal
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.deduplicateVertices(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 2), mesh.vertices.len);
}
