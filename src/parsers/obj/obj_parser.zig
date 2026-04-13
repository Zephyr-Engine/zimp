const std = @import("std");

const raw_mesh = @import("../../assets/raw/mesh.zig");
const RawMesh = raw_mesh.RawMesh;
const RawVertex = raw_mesh.RawVertex;
const RawSubmesh = raw_mesh.RawSubmesh;

pub const ObjParseError = error{
    InvalidFaceVertex,
    InvalidFloat,
    OutOfMemory,
};

const VertexKey = struct {
    pos: u32,
    uv: u32, // 0 means no UV
    normal: u32, // 0 means no normal
};

pub const ObjParser = struct {
    allocator: std.mem.Allocator,
    file_bytes: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_path: []const u8) !ObjParser {
        const file_bytes = try dir.readFileAlloc(io, file_path, allocator, .unlimited);
        return .{
            .allocator = allocator,
            .file_bytes = file_bytes,
        };
    }

    pub fn parse(self: *const ObjParser, allocator: std.mem.Allocator) ObjParseError!RawMesh {
        var positions: std.ArrayList([3]f32) = .empty;
        defer positions.deinit(allocator);
        var normals: std.ArrayList([3]f32) = .empty;
        defer normals.deinit(allocator);
        var uvs: std.ArrayList([2]f32) = .empty;
        defer uvs.deinit(allocator);

        var vertices: std.ArrayList(RawVertex) = .empty;
        errdefer vertices.deinit(allocator);
        var indices: std.ArrayList(u32) = .empty;
        errdefer indices.deinit(allocator);

        var vertex_map = std.AutoHashMap(VertexKey, u32).init(allocator);
        defer vertex_map.deinit();

        var lines = std.mem.splitScalar(u8, self.file_bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, &.{'\r'});
            if (line.len == 0) {
                continue;
            }

            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            const prefix = tokens.next() orelse continue;

            if (prefix[0] == '#') {
                continue;
            }

            if (std.mem.eql(u8, prefix, "v")) {
                const pos = parseFloats(3, &tokens) orelse return error.InvalidFloat;
                try positions.append(allocator, pos);
            } else if (std.mem.eql(u8, prefix, "vn")) {
                const n = parseFloats(3, &tokens) orelse return error.InvalidFloat;
                try normals.append(allocator, n);
            } else if (std.mem.eql(u8, prefix, "vt")) {
                const uv = parseFloats(2, &tokens) orelse return error.InvalidFloat;
                try uvs.append(allocator, uv);
            } else if (std.mem.eql(u8, prefix, "f")) {
                try parseFace(
                    allocator,
                    &tokens,
                    positions.items,
                    normals.items,
                    uvs.items,
                    &vertices,
                    &indices,
                    &vertex_map,
                );
            }
            // Skip: mtllib, usemtl, s, g, o, and anything else
        }

        const submesh = try allocator.alloc(RawSubmesh, 1);
        submesh[0] = .{
            .index_offset = 0,
            .index_count = @intCast(indices.items.len),
            .material_index = 0,
        };

        return .{
            .vertices = try vertices.toOwnedSlice(allocator),
            .indices = try indices.toOwnedSlice(allocator),
            .submeshes = submesh,
            .name = null,
        };
    }

    pub fn deinit(self: *ObjParser) void {
        self.allocator.free(self.file_bytes);
    }
};

fn parseFloats(comptime N: usize, tokens: *std.mem.TokenIterator(u8, .scalar)) ?[N]f32 {
    var result: [N]f32 = undefined;
    for (0..N) |i| {
        const tok = tokens.next() orelse return null;
        result[i] = std.fmt.parseFloat(f32, tok) catch return null;
    }
    return result;
}

fn parseFace(
    allocator: std.mem.Allocator,
    tokens: *std.mem.TokenIterator(u8, .scalar),
    positions: [][3]f32,
    normals_list: [][3]f32,
    uvs_list: [][2]f32,
    vertices: *std.ArrayList(RawVertex),
    indices: *std.ArrayList(u32),
    vertex_map: *std.AutoHashMap(VertexKey, u32),
) ObjParseError!void {
    var face_buf: [16]u32 = undefined;
    var face_len: usize = 0;

    while (tokens.next()) |tok| {
        const key = parseFaceVertex(tok, positions.len, normals_list.len, uvs_list.len) orelse
            return error.InvalidFaceVertex;

        const entry = try vertex_map.getOrPut(key);
        if (!entry.found_existing) {
            const idx: u32 = @intCast(vertices.items.len);
            entry.value_ptr.* = idx;

            const pos = positions[key.pos - 1];
            const normal: ?[3]f32 = if (key.normal != 0) normals_list[key.normal - 1] else null;
            const uv: ?[2]f32 = if (key.uv != 0) uvs_list[key.uv - 1] else null;

            try vertices.append(allocator, .{
                .position = pos,
                .normal = normal,
                .tangent = null,
                .uv0 = uv,
                .uv1 = null,
                .joint_indices = null,
                .joint_weights = null,
            });
        }

        if (face_len >= face_buf.len) {
            return error.InvalidFaceVertex;
        }
        face_buf[face_len] = entry.value_ptr.*;
        face_len += 1;
    }

    // Fan triangulation: (v0, v1, v2), (v0, v2, v3), ...
    if (face_len < 3) return error.InvalidFaceVertex;
    const fi = face_buf[0..face_len];
    for (2..fi.len) |i| {
        try indices.append(allocator, fi[0]);
        try indices.append(allocator, fi[i - 1]);
        try indices.append(allocator, fi[i]);
    }
}

/// Parse a face vertex spec: `pos`, `pos/uv`, `pos/uv/normal`, or `pos//normal`.
/// OBJ indices are 1-based; negative indices are relative to the end of the current list.
/// Returns 1-based indices (0 means absent) so the caller can index with `key.pos - 1`.
fn parseFaceVertex(tok: []const u8, pos_count: usize, normal_count: usize, uv_count: usize) ?VertexKey {
    var parts = std.mem.splitScalar(u8, tok, '/');
    const pos_str = parts.next() orelse return null;
    const pos = resolveIndex(pos_str, pos_count) orelse return null;

    const uv_str = parts.next();
    const normal_str = parts.next();

    const uv: u32 = if (uv_str) |s| (if (s.len == 0) 0 else resolveIndex(s, uv_count) orelse return null) else 0;
    const normal: u32 = if (normal_str) |s| (if (s.len == 0) 0 else resolveIndex(s, normal_count) orelse return null) else 0;

    return .{ .pos = pos, .uv = uv, .normal = normal };
}

/// Parse an OBJ index (1-based, possibly negative) and return a 1-based positive index.
fn resolveIndex(s: []const u8, count: usize) ?u32 {
    const val = std.fmt.parseInt(i32, s, 10) catch return null;
    if (val > 0) return @intCast(val);
    if (val < 0) {
        const resolved = @as(i32, @intCast(count)) + val + 1;
        if (resolved < 1) return null;
        return @intCast(resolved);
    }
    return null; // 0 is invalid in OBJ
}

const testing = std.testing;

test "parseFloats parses 3 floats" {
    var tokens = std.mem.tokenizeScalar(u8, "1.0 2.5 -3.0", ' ');
    const result = parseFloats(3, &tokens).?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), result[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.5), result[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -3.0), result[2], 0.001);
}

test "parseFloats returns null on missing token" {
    var tokens = std.mem.tokenizeScalar(u8, "1.0 2.5", ' ');
    try testing.expect(parseFloats(3, &tokens) == null);
}

test "parseFaceVertex handles pos only" {
    const key = parseFaceVertex("1", 3, 0, 0).?;
    try testing.expectEqual(@as(u32, 1), key.pos);
    try testing.expectEqual(@as(u32, 0), key.uv);
    try testing.expectEqual(@as(u32, 0), key.normal);
}

test "parseFaceVertex handles pos/uv" {
    const key = parseFaceVertex("2/3", 3, 0, 4).?;
    try testing.expectEqual(@as(u32, 2), key.pos);
    try testing.expectEqual(@as(u32, 3), key.uv);
    try testing.expectEqual(@as(u32, 0), key.normal);
}

test "parseFaceVertex handles pos/uv/normal" {
    const key = parseFaceVertex("1/2/3", 3, 4, 3).?;
    try testing.expectEqual(@as(u32, 1), key.pos);
    try testing.expectEqual(@as(u32, 2), key.uv);
    try testing.expectEqual(@as(u32, 3), key.normal);
}

test "parseFaceVertex handles pos//normal" {
    const key = parseFaceVertex("1//3", 3, 4, 0).?;
    try testing.expectEqual(@as(u32, 1), key.pos);
    try testing.expectEqual(@as(u32, 0), key.uv);
    try testing.expectEqual(@as(u32, 3), key.normal);
}

test "resolveIndex positive" {
    try testing.expectEqual(@as(?u32, 5), resolveIndex("5", 10));
}

test "resolveIndex negative" {
    // -1 with count=10 => 10 + (-1) + 1 = 10
    try testing.expectEqual(@as(?u32, 10), resolveIndex("-1", 10));
    // -3 with count=5 => 5 + (-3) + 1 = 3
    try testing.expectEqual(@as(?u32, 3), resolveIndex("-3", 5));
}

test "resolveIndex zero returns null" {
    try testing.expectEqual(@as(?u32, null), resolveIndex("0", 10));
}

test "resolveIndex negative out of range returns null" {
    try testing.expectEqual(@as(?u32, null), resolveIndex("-5", 3));
}

test "parse simple triangle" {
    const obj_src =
        \\# simple triangle
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };


    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
    try testing.expectEqual(@as(usize, 1), mesh.submeshes.len);
    try testing.expectEqual(@as(u32, 0), mesh.submeshes[0].index_offset);
    try testing.expectEqual(@as(u32, 3), mesh.submeshes[0].index_count);
}

test "parse quad is triangulated into 2 triangles" {
    const obj_src =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 1.0 1.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3 4
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };

    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    try testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 6), mesh.indices.len);
}

test "parse with normals and UVs" {
    const obj_src =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\vn 0.0 0.0 1.0
        \\vt 0.0 0.0
        \\vt 1.0 0.0
        \\vt 0.0 1.0
        \\f 1/1/1 2/2/1 3/3/1
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };


    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expect(mesh.vertices[0].normal != null);
    try testing.expect(mesh.vertices[0].uv0 != null);
}

test "parse deduplicates shared vertices" {
    const obj_src =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 1.0 1.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3
        \\f 1 3 4
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };


    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    // Vertices 1 and 3 are shared across both faces
    try testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 6), mesh.indices.len);
}

test "parse with negative indices" {
    const obj_src =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\f -3 -2 -1
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };


    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
}

test "parse skips comments and unknown lines" {
    const obj_src =
        \\# this is a comment
        \\mtllib material.mtl
        \\o MyObject
        \\g group1
        \\usemtl material1
        \\s off
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };


    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
}

test "parse pos//normal format" {
    const obj_src =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\vn 0.0 0.0 1.0
        \\f 1//1 2//1 3//1
    ;

    const parser = ObjParser{
        .allocator = testing.allocator,
        .file_bytes = obj_src,
    };


    const mesh = try parser.parse(testing.allocator);
    defer {
        testing.allocator.free(mesh.vertices);
        testing.allocator.free(mesh.indices);
        testing.allocator.free(mesh.submeshes);
    }

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expect(mesh.vertices[0].normal != null);
    try testing.expect(mesh.vertices[0].uv0 == null);
}
