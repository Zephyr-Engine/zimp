const std = @import("std");
const log = @import("../../logger.zig");
const Map = std.AutoHashMap(u64, u32);
const ReMap = std.AutoHashMap(u32, u32);

pub const RawVertex = struct {
    position: [3]f32,
    normal: ?[3]f32,
    tangent: ?[4]f32,
    uv0: ?[2]f32,
    uv1: ?[2]f32,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f32,

    pub fn hash(self: *const RawVertex) u64 {
        return std.hash.XxHash64.hash(0, std.mem.asBytes(self));
    }

    pub fn quantizeUV0(self: *const RawVertex) ?[2]u16 {
        if (self.uv0) |uv| {
            return quantizeUV(uv);
        }
        return null;
    }

    pub fn quantizeUV1(self: *const RawVertex) ?[2]u16 {
        if (self.uv1) |uv| {
            return quantizeUV(uv);
        }
        return null;
    }

    pub fn quantizeTangent(self: *const RawVertex) ?[4]f16 {
        if (self.tangent) |tangent| {
            var result: [4]f16 = undefined;
            for (0..4) |i| {
                result[i] = @floatCast(tangent[i]);
            }

            return result;
        }

        return null;
    }

    pub fn quantizeJointWeights(self: *const RawVertex) ?[4]f16 {
        if (self.joint_weights) |weights| {
            var result: [4]f16 = undefined;
            for (0..4) |i| {
                result[i] = @floatCast(weights[i]);
            }

            return result;
        }

        return null;
    }

    pub fn encodeNormalOctahedral(self: *const RawVertex) ?[2]i16 {
        if (self.normal) |normal| {
            const abs_sum = @abs(normal[0]) + @abs(normal[1]) + @abs(normal[2]);

            // Project onto octahedron
            var oct: [2]f32 = .{
                normal[0] / abs_sum,
                normal[1] / abs_sum,
            };

            // Fold for negative z hemisphere
            if (normal[2] < 0.0) {
                const ox = oct[0];
                const oy = oct[1];
                oct[0] = (1.0 - @abs(oy)) * signNonZero(ox);
                oct[1] = (1.0 - @abs(ox)) * signNonZero(oy);
            }

            return .{
                @intFromFloat(oct[0] * 32767.0),
                @intFromFloat(oct[1] * 32767.0),
            };
        }

        return null;
    }

    /// Like std.math.sign but returns 1.0 for zero (needed for octahedral fold).
    fn signNonZero(x: f32) f32 {
        return if (x >= 0.0) 1.0 else -1.0;
    }

    fn quantizeUV(uv: [2]f32) [2]u16 {
        var result: [2]u16 = undefined;
        for (0..2) |i| {
            if (uv[i] < 0.0 or uv[i] > 1.0) {
                log.warn("Found UV outside 0-1 range: {d}", .{uv[i]});
            }

            const clamped = std.math.clamp(uv[i], 0.0, 1.0);
            result[i] = @intFromFloat(clamped * 65525.0);
        }

        return result;
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

    pub fn optimize(self: *RawMesh, allocator: std.mem.Allocator) !void {
        try self.deduplicateVertices(allocator);
        try self.optimizeVertexCache(allocator);
    }

    // Forsyth Algorithm
    fn optimizeVertexCache(self: *RawMesh, allocator: std.mem.Allocator) !void {
        // TODO: implement
        _ = allocator;
        _ = self;
    }

    fn deduplicateVertices(self: *RawMesh, allocator: std.mem.Allocator) !void {
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
                log.warn("Hash collision detected at vertex {d}", .{i});
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

        log.debug("[Optimizing Mesh] Deduplicated {d} -> {d} vertices", .{ original_len, self.vertices.len });
    }
};

// Tests

fn makeVertex(x: f32, y: f32, z: f32) RawVertex {
    return .{
        .position = .{ x, y, z },
        .normal = null,
        .tangent = null,
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

test "quantizeUV maps 0.0 to 0 and 1.0 to 65525" {
    const result = RawVertex.quantizeUV(.{ 0.0, 1.0 });
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 65525), result[1]);
}

test "quantizeUV maps 0.5 to midpoint" {
    const result = RawVertex.quantizeUV(.{ 0.5, 0.5 });
    // 0.5 * 65525 = 32762.5 → truncated to 32762
    try std.testing.expectEqual(@as(u16, 32762), result[0]);
    try std.testing.expectEqual(@as(u16, 32762), result[1]);
}

test "quantizeUV clamps values below 0" {
    const result = RawVertex.quantizeUV(.{ -0.5, -1.0 });
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 0), result[1]);
}

test "quantizeUV clamps values above 1" {
    const result = RawVertex.quantizeUV(.{ 1.5, 2.0 });
    try std.testing.expectEqual(@as(u16, 65525), result[0]);
    try std.testing.expectEqual(@as(u16, 65525), result[1]);
}

test "quantizeUV handles independent channels" {
    const result = RawVertex.quantizeUV(.{ 0.25, 0.75 });
    // 0.25 * 65525 = 16381.25 → 16381
    // 0.75 * 65525 = 49143.75 → 49143
    try std.testing.expectEqual(@as(u16, 16381), result[0]);
    try std.testing.expectEqual(@as(u16, 49143), result[1]);
}

test "quantizeUV0 returns quantized value when present" {
    var v = makeVertex(0, 0, 0);
    v.uv0 = .{ 0.0, 1.0 };
    const result = v.quantizeUV0().?;
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 65525), result[1]);
}

test "quantizeUV0 returns null when absent" {
    const v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[2]u16, null), v.quantizeUV0());
}

test "quantizeUV1 returns quantized value when present" {
    var v = makeVertex(0, 0, 0);
    v.uv1 = .{ 0.5, 0.25 };
    const result = v.quantizeUV1().?;
    try std.testing.expectEqual(@as(u16, 32762), result[0]);
    try std.testing.expectEqual(@as(u16, 16381), result[1]);
}

test "quantizeUV1 returns null when absent" {
    const v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[2]u16, null), v.quantizeUV1());
}

test "quantizeTangent converts f32 to f16" {
    var v = makeVertex(0, 0, 0);
    v.tangent = .{ 1.0, 0.0, 0.0, 1.0 };
    const result = v.quantizeTangent().?;
    try std.testing.expectEqual(@as(f16, 1.0), result[0]);
    try std.testing.expectEqual(@as(f16, 0.0), result[1]);
    try std.testing.expectEqual(@as(f16, 0.0), result[2]);
    try std.testing.expectEqual(@as(f16, 1.0), result[3]);
}

test "quantizeTangent returns null when absent" {
    const v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[4]f16, null), v.quantizeTangent());
}

test "quantizeTangent preserves negative values" {
    var v = makeVertex(0, 0, 0);
    v.tangent = .{ -1.0, 0.5, -0.5, -1.0 };
    const result = v.quantizeTangent().?;
    try std.testing.expectEqual(@as(f16, -1.0), result[0]);
    try std.testing.expectEqual(@as(f16, 0.5), result[1]);
    try std.testing.expectEqual(@as(f16, -0.5), result[2]);
    try std.testing.expectEqual(@as(f16, -1.0), result[3]);
}

test "quantizeJointWeights converts f32 to f16" {
    var v = makeVertex(0, 0, 0);
    v.joint_weights = .{ 1.0, 0.0, 0.0, 0.0 };
    const result = v.quantizeJointWeights().?;
    try std.testing.expectEqual(@as(f16, 1.0), result[0]);
    try std.testing.expectEqual(@as(f16, 0.0), result[1]);
    try std.testing.expectEqual(@as(f16, 0.0), result[2]);
    try std.testing.expectEqual(@as(f16, 0.0), result[3]);
}

test "quantizeJointWeights returns null when absent" {
    const v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[4]f16, null), v.quantizeJointWeights());
}

test "quantizeJointWeights handles fractional weights" {
    var v = makeVertex(0, 0, 0);
    v.joint_weights = .{ 0.5, 0.25, 0.125, 0.125 };
    const result = v.quantizeJointWeights().?;
    try std.testing.expectEqual(@as(f16, 0.5), result[0]);
    try std.testing.expectEqual(@as(f16, 0.25), result[1]);
    try std.testing.expectEqual(@as(f16, 0.125), result[2]);
    try std.testing.expectEqual(@as(f16, 0.125), result[3]);
}

test "quantizeJointWeights still sum to 1 after quantization" {
    var v = makeVertex(0, 0, 0);
    v.joint_weights = .{ 0.6, 0.2, 0.15, 0.05 };
    const result = v.quantizeJointWeights().?;
    const sum: f16 = result[0] + result[1] + result[2] + result[3];
    try std.testing.expectApproxEqAbs(@as(f16, 1.0), sum, 0.01);
}

/// Decode octahedral-encoded normal back to a unit vector (test helper).
fn decodeOctahedral(encoded: [2]i16) [3]f32 {
    var oct: [2]f32 = .{
        @as(f32, @floatFromInt(encoded[0])) / 32767.0,
        @as(f32, @floatFromInt(encoded[1])) / 32767.0,
    };

    const z = 1.0 - @abs(oct[0]) - @abs(oct[1]);

    if (z < 0.0) {
        const ox = oct[0];
        const oy = oct[1];
        oct[0] = (1.0 - @abs(oy)) * RawVertex.signNonZero(ox);
        oct[1] = (1.0 - @abs(ox)) * RawVertex.signNonZero(oy);
    }

    // Normalize
    const len = @sqrt(oct[0] * oct[0] + oct[1] * oct[1] + z * z);
    return .{ oct[0] / len, oct[1] / len, z / len };
}

fn expectNormalApproxEq(expected: [3]f32, actual: [3]f32, tolerance: f32) !void {
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(expected[i], actual[i], tolerance);
    }
}

test "octahedral encode/decode [0, 0, 1] (up)" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 0, 0, 1 };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ 0, 0, 1 }, decoded, 0.001);
}

test "octahedral encode/decode [1, 0, 0] (right)" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 1, 0, 0 };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ 1, 0, 0 }, decoded, 0.001);
}

test "octahedral encode/decode [0.577, 0.577, 0.577] (diagonal)" {
    var v = makeVertex(0, 0, 0);
    const s = 1.0 / @sqrt(3.0);
    v.normal = .{ s, s, s };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ s, s, s }, decoded, 0.001);
}

test "octahedral encode/decode [0, 0, -1] (down, exercises fold)" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 0, 0, -1 };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ 0, 0, -1 }, decoded, 0.001);
}

test "encodeNormalOctahedral returns null when normal is absent" {
    const v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[2]i16, null), v.encodeNormalOctahedral());
}

test "octahedral encode/decode 1000 random normals within 1 degree" {
    // 1 degree in radians
    const max_angle = 1.0 * std.math.pi / 180.0;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    for (0..1000) |_| {
        // Generate random unit normal via spherical coordinates
        const theta = rand.float(f32) * 2.0 * std.math.pi;
        const cos_phi = rand.float(f32) * 2.0 - 1.0;
        const sin_phi = @sqrt(1.0 - cos_phi * cos_phi);

        const normal: [3]f32 = .{
            sin_phi * @cos(theta),
            sin_phi * @sin(theta),
            cos_phi,
        };

        var v = makeVertex(0, 0, 0);
        v.normal = normal;
        const encoded = v.encodeNormalOctahedral().?;
        const decoded = decodeOctahedral(encoded);

        // Angular error: acos(dot(normal, decoded))
        const dot = normal[0] * decoded[0] + normal[1] * decoded[1] + normal[2] * decoded[2];
        const angle = std.math.acos(std.math.clamp(dot, -1.0, 1.0));
        try std.testing.expect(angle < max_angle);
    }
}
