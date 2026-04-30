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
        try self.removeDegenerateTriangles(allocator);
        try self.removeUnusedVertices(allocator);
        try self.deduplicateVertices(allocator);
        try self.removeDegenerateTriangles(allocator);
        try self.removeUnusedVertices(allocator);
        try self.optimizeVertexCache(allocator);
        try self.optimizeVertexFetch(allocator);
    }

    fn removeDegenerateTriangles(self: *RawMesh, allocator: std.mem.Allocator) !void {
        if (self.indices.len == 0) {
            return;
        }

        if (self.submeshes.len == 0) {
            if (self.indices.len % 3 != 0) {
                return;
            }
        } else {
            for (self.submeshes) |submesh| {
                const offset: usize = submesh.index_offset;
                const count: usize = submesh.index_count;
                if (offset > self.indices.len or count > self.indices.len - offset) {
                    return error.InvalidSubmeshRange;
                }
                if (count % 3 != 0) {
                    return;
                }
            }
        }

        const cleaned = try allocator.alloc(u32, self.indices.len);
        errdefer allocator.free(cleaned);

        const original_len = self.indices.len;
        var cleaned_len: usize = 0;

        if (self.submeshes.len == 0) {
            cleaned_len = try copyValidTriangles(self.vertices, self.indices, cleaned, 0, self.indices.len);
        } else {
            for (self.submeshes) |*submesh| {
                const offset: usize = submesh.index_offset;
                const count: usize = submesh.index_count;
                const new_offset = cleaned_len;
                const kept_count = try copyValidTriangles(self.vertices, self.indices, cleaned[cleaned_len..], offset, count);
                submesh.index_offset = @intCast(new_offset);
                submesh.index_count = @intCast(kept_count);
                cleaned_len += kept_count;
            }
        }

        if (cleaned_len == original_len) {
            allocator.free(cleaned);
            return;
        }

        const new_indices = try allocator.dupe(u32, cleaned[0..cleaned_len]);
        allocator.free(cleaned);
        allocator.free(self.indices);
        self.indices = new_indices;

        log.debug("[Optimizing Mesh] Removed {d} degenerate triangle indices", .{original_len - cleaned_len});
    }

    // Forsyth Algorithm
    fn optimizeVertexCache(self: *RawMesh, allocator: std.mem.Allocator) !void {
        if (self.indices.len < 6 or self.indices.len % 3 != 0) {
            return;
        }

        const optimized = try allocator.dupe(u32, self.indices);
        errdefer allocator.free(optimized);

        if (self.submeshes.len == 0) {
            try optimizeVertexCacheRange(allocator, self.vertices.len, self.indices, optimized, 0, self.indices.len);
        } else {
            for (self.submeshes) |submesh| {
                const offset: usize = submesh.index_offset;
                const count: usize = submesh.index_count;
                if (offset > self.indices.len or count > self.indices.len - offset) {
                    return error.InvalidSubmeshRange;
                }
                if (count % 3 != 0) {
                    return;
                }
                try optimizeVertexCacheRange(allocator, self.vertices.len, self.indices, optimized, offset, count);
            }
        }

        allocator.free(self.indices);
        self.indices = optimized;
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

    fn removeUnusedVertices(self: *RawMesh, allocator: std.mem.Allocator) !void {
        if (self.vertices.len == 0) {
            return;
        }

        var used = try allocator.alloc(bool, self.vertices.len);
        defer allocator.free(used);
        @memset(used, false);

        for (self.indices) |index| {
            if (index >= self.vertices.len) {
                return error.InvalidMeshIndex;
            }
            used[index] = true;
        }

        var used_count: usize = 0;
        for (used) |is_used| {
            if (is_used) {
                used_count += 1;
            }
        }

        if (used_count == self.vertices.len) {
            return;
        }

        const remap = try allocator.alloc(u32, self.vertices.len);
        defer allocator.free(remap);

        const compacted = try allocator.alloc(RawVertex, used_count);
        errdefer allocator.free(compacted);

        var next_vertex: u32 = 0;
        for (self.vertices, used, 0..) |vertex, is_used, old_index| {
            if (is_used) {
                remap[old_index] = next_vertex;
                compacted[next_vertex] = vertex;
                next_vertex += 1;
            }
        }

        for (self.indices) |*index| {
            index.* = remap[index.*];
        }

        const original_len = self.vertices.len;
        allocator.free(self.vertices);
        self.vertices = compacted;

        log.debug("[Optimizing Mesh] Removed {d} unused vertices", .{original_len - self.vertices.len});
    }

    fn optimizeVertexFetch(self: *RawMesh, allocator: std.mem.Allocator) !void {
        if (self.vertices.len == 0 or self.indices.len == 0) {
            return;
        }

        const unset = std.math.maxInt(u32);
        var remap = try allocator.alloc(u32, self.vertices.len);
        defer allocator.free(remap);
        @memset(remap, unset);

        const reordered = try allocator.alloc(RawVertex, self.vertices.len);
        errdefer allocator.free(reordered);

        var next_vertex: u32 = 0;
        for (self.indices) |*index| {
            if (index.* >= self.vertices.len) {
                return error.InvalidMeshIndex;
            }

            const old_index = index.*;
            if (remap[old_index] == unset) {
                remap[old_index] = next_vertex;
                reordered[next_vertex] = self.vertices[old_index];
                next_vertex += 1;
            }
            index.* = remap[old_index];
        }

        for (self.vertices, 0..) |vertex, old_index| {
            if (remap[old_index] == unset) {
                remap[old_index] = next_vertex;
                reordered[next_vertex] = vertex;
                next_vertex += 1;
            }
        }

        allocator.free(self.vertices);
        self.vertices = reordered;
    }
};

const forsyth_cache_size = 32;
const forsyth_last_triangle_score: f32 = 0.75;
const forsyth_cache_decay_power: f32 = 1.5;
const forsyth_valence_boost_scale: f32 = 2.0;
const forsyth_valence_boost_power: f32 = 0.5;
const degenerate_triangle_area_epsilon_sq: f32 = 1.0e-20;

fn copyValidTriangles(
    vertices: []const RawVertex,
    source_indices: []const u32,
    dest_indices: []u32,
    index_offset: usize,
    index_count: usize,
) !usize {
    if (index_count % 3 != 0) {
        return error.InvalidTriangleIndexBuffer;
    }

    var written: usize = 0;
    var triangle_start = index_offset;
    while (triangle_start < index_offset + index_count) : (triangle_start += 3) {
        const a = source_indices[triangle_start + 0];
        const b = source_indices[triangle_start + 1];
        const c = source_indices[triangle_start + 2];
        if (a >= vertices.len or b >= vertices.len or c >= vertices.len) {
            return error.InvalidMeshIndex;
        }
        if (isDegenerateTriangle(vertices, a, b, c)) {
            continue;
        }

        dest_indices[written + 0] = a;
        dest_indices[written + 1] = b;
        dest_indices[written + 2] = c;
        written += 3;
    }

    return written;
}

fn isDegenerateTriangle(vertices: []const RawVertex, a: u32, b: u32, c: u32) bool {
    if (a == b or b == c or c == a) {
        return true;
    }

    const p0 = vertices[a].position;
    const p1 = vertices[b].position;
    const p2 = vertices[c].position;

    const e0 = [3]f32{
        p1[0] - p0[0],
        p1[1] - p0[1],
        p1[2] - p0[2],
    };
    const e1 = [3]f32{
        p2[0] - p0[0],
        p2[1] - p0[1],
        p2[2] - p0[2],
    };
    const cross = [3]f32{
        e0[1] * e1[2] - e0[2] * e1[1],
        e0[2] * e1[0] - e0[0] * e1[2],
        e0[0] * e1[1] - e0[1] * e1[0],
    };
    const area_sq = cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2];
    return area_sq <= degenerate_triangle_area_epsilon_sq;
}

fn optimizeVertexCacheRange(
    allocator: std.mem.Allocator,
    vertex_count: usize,
    source: []const u32,
    dest: []u32,
    index_offset: usize,
    index_count: usize,
) !void {
    if (index_count == 0) {
        return;
    }
    if (index_count % 3 != 0) {
        return error.InvalidTriangleIndexBuffer;
    }

    const triangle_count = index_count / 3;
    if (triangle_count <= 1) {
        return;
    }

    const range = source[index_offset .. index_offset + index_count];

    var active_triangle_counts = try allocator.alloc(u32, vertex_count);
    defer allocator.free(active_triangle_counts);
    @memset(active_triangle_counts, 0);

    for (range) |index| {
        if (index >= vertex_count) {
            return error.InvalidMeshIndex;
        }
        active_triangle_counts[index] += 1;
    }

    var adjacency_offsets = try allocator.alloc(u32, vertex_count + 1);
    defer allocator.free(adjacency_offsets);
    adjacency_offsets[0] = 0;
    for (active_triangle_counts, 0..) |count, vertex_index| {
        adjacency_offsets[vertex_index + 1] = adjacency_offsets[vertex_index] + count;
    }

    var adjacency = try allocator.alloc(u32, adjacency_offsets[vertex_count]);
    defer allocator.free(adjacency);

    var adjacency_cursors = try allocator.dupe(u32, adjacency_offsets[0..vertex_count]);
    defer allocator.free(adjacency_cursors);

    for (0..triangle_count) |triangle_index| {
        const triangle_start = triangle_index * 3;
        for (0..3) |corner| {
            const vertex_index = range[triangle_start + corner];
            const write_index = adjacency_cursors[vertex_index];
            adjacency[write_index] = @intCast(triangle_index);
            adjacency_cursors[vertex_index] = write_index + 1;
        }
    }

    var cache_positions = try allocator.alloc(i32, vertex_count);
    defer allocator.free(cache_positions);
    @memset(cache_positions, -1);

    var vertex_scores = try allocator.alloc(f32, vertex_count);
    defer allocator.free(vertex_scores);
    for (0..vertex_count) |vertex_index| {
        vertex_scores[vertex_index] = forsythVertexScore(cache_positions[vertex_index], active_triangle_counts[vertex_index]);
    }

    var triangle_scores = try allocator.alloc(f32, triangle_count);
    defer allocator.free(triangle_scores);
    for (0..triangle_count) |triangle_index| {
        triangle_scores[triangle_index] = forsythTriangleScore(range, triangle_index, vertex_scores);
    }

    var emitted = try allocator.alloc(bool, triangle_count);
    defer allocator.free(emitted);
    @memset(emitted, false);

    var cache: [forsyth_cache_size]u32 = undefined;
    var cache_len: usize = 0;
    var emitted_count: usize = 0;
    var scan_cursor: usize = 0;

    while (emitted_count < triangle_count) {
        const triangle_index = findBestForsythTriangle(
            &cache,
            cache_len,
            adjacency_offsets,
            adjacency,
            triangle_scores,
            emitted,
            &scan_cursor,
        ) orelse return error.InvalidTriangleIndexBuffer;

        emitted[triangle_index] = true;

        const triangle_start = triangle_index * 3;
        const output_start = index_offset + emitted_count * 3;
        dest[output_start + 0] = range[triangle_start + 0];
        dest[output_start + 1] = range[triangle_start + 1];
        dest[output_start + 2] = range[triangle_start + 2];
        emitted_count += 1;

        var affected_vertices: [forsyth_cache_size * 2 + 3]u32 = undefined;
        var affected_count: usize = 0;
        appendAffectedVertices(&affected_vertices, &affected_count, cache[0..cache_len]);

        for (cache[0..cache_len]) |vertex_index| {
            cache_positions[vertex_index] = -1;
        }

        for (0..3) |corner| {
            const vertex_index = range[triangle_start + corner];
            if (active_triangle_counts[vertex_index] == 0) {
                return error.InvalidTriangleIndexBuffer;
            }
            active_triangle_counts[vertex_index] -= 1;
            appendAffectedVertex(&affected_vertices, &affected_count, vertex_index);
        }

        var corner: usize = 3;
        while (corner > 0) {
            corner -= 1;
            promoteVertexInForsythCache(&cache, &cache_len, range[triangle_start + corner]);
        }

        for (cache[0..cache_len], 0..) |vertex_index, cache_position| {
            cache_positions[vertex_index] = @intCast(cache_position);
        }
        appendAffectedVertices(&affected_vertices, &affected_count, cache[0..cache_len]);

        for (affected_vertices[0..affected_count]) |vertex_index| {
            vertex_scores[vertex_index] = forsythVertexScore(cache_positions[vertex_index], active_triangle_counts[vertex_index]);
        }

        for (affected_vertices[0..affected_count]) |vertex_index| {
            const adjacency_start = adjacency_offsets[vertex_index];
            const adjacency_end = adjacency_offsets[vertex_index + 1];
            for (adjacency[adjacency_start..adjacency_end]) |adjacent_triangle_index| {
                if (!emitted[adjacent_triangle_index]) {
                    triangle_scores[adjacent_triangle_index] = forsythTriangleScore(range, adjacent_triangle_index, vertex_scores);
                }
            }
        }
    }
}

fn forsythVertexScore(cache_position: i32, active_triangle_count: u32) f32 {
    if (active_triangle_count == 0) {
        return 0.0;
    }

    var score: f32 = 0.0;
    if (cache_position >= 0) {
        if (cache_position < 3) {
            score = forsyth_last_triangle_score;
        } else if (cache_position < forsyth_cache_size) {
            const cache_position_f: f32 = @floatFromInt(cache_position - 3);
            const cache_range: f32 = @floatFromInt(forsyth_cache_size - 3);
            const scaler = 1.0 / cache_range;
            score = std.math.pow(f32, 1.0 - cache_position_f * scaler, forsyth_cache_decay_power);
        }
    }

    const active_triangle_count_f: f32 = @floatFromInt(active_triangle_count);
    score += forsyth_valence_boost_scale * std.math.pow(f32, active_triangle_count_f, -forsyth_valence_boost_power);
    return score;
}

fn forsythTriangleScore(indices: []const u32, triangle_index: usize, vertex_scores: []const f32) f32 {
    const triangle_start = triangle_index * 3;
    return vertex_scores[indices[triangle_start + 0]] +
        vertex_scores[indices[triangle_start + 1]] +
        vertex_scores[indices[triangle_start + 2]];
}

fn findBestForsythTriangle(
    cache: *const [forsyth_cache_size]u32,
    cache_len: usize,
    adjacency_offsets: []const u32,
    adjacency: []const u32,
    triangle_scores: []const f32,
    emitted: []const bool,
    scan_cursor: *usize,
) ?usize {
    var best_triangle: ?usize = null;
    var best_score: f32 = -std.math.inf(f32);

    for (cache[0..cache_len]) |vertex_index| {
        const adjacency_start = adjacency_offsets[vertex_index];
        const adjacency_end = adjacency_offsets[vertex_index + 1];
        for (adjacency[adjacency_start..adjacency_end]) |triangle_index| {
            if (emitted[triangle_index]) {
                continue;
            }
            const score = triangle_scores[triangle_index];
            if (best_triangle == null or score > best_score) {
                best_triangle = triangle_index;
                best_score = score;
            }
        }
    }

    if (best_triangle != null) {
        return best_triangle;
    }

    while (scan_cursor.* < emitted.len and emitted[scan_cursor.*]) {
        scan_cursor.* += 1;
    }

    var triangle_index = scan_cursor.*;
    while (triangle_index < emitted.len) : (triangle_index += 1) {
        if (emitted[triangle_index]) {
            continue;
        }
        const score = triangle_scores[triangle_index];
        if (best_triangle == null or score > best_score) {
            best_triangle = triangle_index;
            best_score = score;
        }
    }

    return best_triangle;
}

fn promoteVertexInForsythCache(cache: *[forsyth_cache_size]u32, cache_len: *usize, vertex_index: u32) void {
    var existing_position: ?usize = null;
    for (cache[0..cache_len.*], 0..) |cached_vertex, cache_position| {
        if (cached_vertex == vertex_index) {
            existing_position = cache_position;
            break;
        }
    }

    const write_len = if (existing_position == null and cache_len.* < forsyth_cache_size) cache_len.* + 1 else cache_len.*;
    var position = if (write_len == 0) 0 else write_len - 1;
    while (position > 0) : (position -= 1) {
        if (existing_position) |existing| {
            if (position > existing) {
                continue;
            }
        }
        cache[position] = cache[position - 1];
    }

    cache[0] = vertex_index;
    cache_len.* = write_len;
}

fn appendAffectedVertex(affected_vertices: []u32, affected_count: *usize, vertex_index: u32) void {
    for (affected_vertices[0..affected_count.*]) |affected_vertex| {
        if (affected_vertex == vertex_index) {
            return;
        }
    }

    affected_vertices[affected_count.*] = vertex_index;
    affected_count.* += 1;
}

fn appendAffectedVertices(affected_vertices: []u32, affected_count: *usize, vertices: []const u32) void {
    for (vertices) |vertex_index| {
        appendAffectedVertex(affected_vertices, affected_count, vertex_index);
    }
}

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

fn countVertexCacheMisses(indices: []const u32) usize {
    var cache: [forsyth_cache_size]u32 = undefined;
    var cache_len: usize = 0;
    var misses: usize = 0;

    for (indices) |index| {
        var cache_hit = false;
        for (cache[0..cache_len]) |cached_index| {
            if (cached_index == index) {
                cache_hit = true;
                break;
            }
        }

        if (!cache_hit) {
            misses += 1;
        }

        promoteVertexInForsythCache(&cache, &cache_len, index);
    }

    return misses;
}

fn expectSameTriangles(allocator: std.mem.Allocator, expected: []const u32, actual: []const u32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    try std.testing.expectEqual(@as(usize, 0), expected.len % 3);

    const triangle_count = expected.len / 3;
    var matched = try allocator.alloc(bool, triangle_count);
    defer allocator.free(matched);
    @memset(matched, false);

    for (0..triangle_count) |expected_triangle| {
        const expected_start = expected_triangle * 3;
        var found = false;

        for (0..triangle_count) |actual_triangle| {
            if (matched[actual_triangle]) {
                continue;
            }

            const actual_start = actual_triangle * 3;
            if (expected[expected_start + 0] == actual[actual_start + 0] and
                expected[expected_start + 1] == actual[actual_start + 1] and
                expected[expected_start + 2] == actual[actual_start + 2])
            {
                matched[actual_triangle] = true;
                found = true;
                break;
            }
        }

        try std.testing.expect(found);
    }
}

test "removeDegenerateTriangles drops repeated and zero-area triangles and updates submeshes" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(0, 1, 0),
        makeVertex(2, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{
        0, 1, 2, 0, 0, 1,
        0, 1, 3, 2, 1, 3,
    });
    const submeshes = try allocator.dupe(RawSubmesh, &.{
        .{ .index_offset = 0, .index_count = 6, .material_index = 0 },
        .{ .index_offset = 6, .index_count = 6, .material_index = 1 },
    });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = submeshes,
        .name = null,
    };

    try mesh.removeDegenerateTriangles(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);
    defer allocator.free(mesh.submeshes);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 2, 1, 3 }, mesh.indices);
    try std.testing.expectEqual(@as(u32, 0), mesh.submeshes[0].index_offset);
    try std.testing.expectEqual(@as(u32, 3), mesh.submeshes[0].index_count);
    try std.testing.expectEqual(@as(u32, 3), mesh.submeshes[1].index_offset);
    try std.testing.expectEqual(@as(u32, 3), mesh.submeshes[1].index_count);
}

test "removeUnusedVertices compacts vertices in original order and remaps indices" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(2, 0, 0),
        makeVertex(3, 0, 0),
        makeVertex(4, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 4, 2, 4 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.removeUnusedVertices(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 2), mesh.vertices.len);
    try std.testing.expectEqual([3]f32{ 2, 0, 0 }, mesh.vertices[0].position);
    try std.testing.expectEqual([3]f32{ 4, 0, 0 }, mesh.vertices[1].position);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 1 }, mesh.indices);
}

test "optimizeVertexFetch orders referenced vertices by first index use" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(2, 0, 0),
        makeVertex(3, 0, 0),
        makeVertex(4, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 3, 1, 4, 3, 1, 2 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    try mesh.optimizeVertexFetch(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 1, 3 }, mesh.indices);
    try std.testing.expectEqual([3]f32{ 3, 0, 0 }, mesh.vertices[0].position);
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, mesh.vertices[1].position);
    try std.testing.expectEqual([3]f32{ 4, 0, 0 }, mesh.vertices[2].position);
    try std.testing.expectEqual([3]f32{ 2, 0, 0 }, mesh.vertices[3].position);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, mesh.vertices[4].position);
}

test "vertex cache optimization preserves triangles and reduces misses on shuffled grid" {
    const allocator = std.testing.allocator;

    const grid_size = 9;
    const row_vertices = grid_size + 1;
    const vertex_count = row_vertices * row_vertices;
    const triangle_count = grid_size * grid_size * 2;

    const vertices = try allocator.alloc(RawVertex, vertex_count);
    for (0..row_vertices) |y| {
        for (0..row_vertices) |x| {
            vertices[y * row_vertices + x] = makeVertex(@floatFromInt(x), @floatFromInt(y), 0);
        }
    }

    const ordered_indices = try allocator.alloc(u32, triangle_count * 3);
    defer allocator.free(ordered_indices);

    var triangle_index: usize = 0;
    for (0..grid_size) |y| {
        for (0..grid_size) |x| {
            const v0: u32 = @intCast(y * row_vertices + x);
            const v1: u32 = @intCast(y * row_vertices + x + 1);
            const v2: u32 = @intCast((y + 1) * row_vertices + x);
            const v3: u32 = @intCast((y + 1) * row_vertices + x + 1);

            ordered_indices[triangle_index * 3 + 0] = v0;
            ordered_indices[triangle_index * 3 + 1] = v1;
            ordered_indices[triangle_index * 3 + 2] = v2;
            triangle_index += 1;

            ordered_indices[triangle_index * 3 + 0] = v1;
            ordered_indices[triangle_index * 3 + 1] = v3;
            ordered_indices[triangle_index * 3 + 2] = v2;
            triangle_index += 1;
        }
    }

    const indices = try allocator.alloc(u32, triangle_count * 3);
    for (0..triangle_count) |out_triangle| {
        const in_triangle = (out_triangle * 37) % triangle_count;
        indices[out_triangle * 3 + 0] = ordered_indices[in_triangle * 3 + 0];
        indices[out_triangle * 3 + 1] = ordered_indices[in_triangle * 3 + 1];
        indices[out_triangle * 3 + 2] = ordered_indices[in_triangle * 3 + 2];
    }

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    const original_indices = try allocator.dupe(u32, mesh.indices);
    defer allocator.free(original_indices);
    const misses_before = countVertexCacheMisses(mesh.indices);

    try mesh.optimizeVertexCache(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    const misses_after = countVertexCacheMisses(mesh.indices);
    try std.testing.expect(misses_after < misses_before);
    try expectSameTriangles(allocator, original_indices, mesh.indices);
}

test "vertex cache optimization does not move triangles across submesh ranges" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.alloc(RawVertex, 12);
    for (vertices, 0..) |*vertex, i| {
        vertex.* = makeVertex(@floatFromInt(i), 0, 0);
    }

    const indices = try allocator.dupe(u32, &.{
        0, 1, 2, 2, 1, 3, 2, 3, 4,  4,  3, 5,
        6, 7, 8, 8, 7, 9, 8, 9, 10, 10, 9, 11,
    });
    const submeshes = try allocator.dupe(RawSubmesh, &.{
        .{ .index_offset = 0, .index_count = 12, .material_index = 0 },
        .{ .index_offset = 12, .index_count = 12, .material_index = 1 },
    });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = submeshes,
        .name = null,
    };

    const first_submesh_before = try allocator.dupe(u32, mesh.indices[0..12]);
    defer allocator.free(first_submesh_before);
    const second_submesh_before = try allocator.dupe(u32, mesh.indices[12..24]);
    defer allocator.free(second_submesh_before);

    try mesh.optimizeVertexCache(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);
    defer allocator.free(mesh.submeshes);

    try expectSameTriangles(allocator, first_submesh_before, mesh.indices[0..12]);
    try expectSameTriangles(allocator, second_submesh_before, mesh.indices[12..24]);
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
