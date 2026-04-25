const std = @import("std");

const raw_mesh = @import("../../assets/raw/mesh.zig");
const RawMesh = raw_mesh.RawMesh;
const RawVertex = raw_mesh.RawVertex;
const RawSubmesh = raw_mesh.RawSubmesh;

pub const ObjParseError = error{
    InvalidFaceVertex,
    InvalidFloat,
    OutOfMemory,
    ReadFailed,
    StreamTooLong,
};

const VertexKey = struct {
    pos: u32,
    uv: u32, // 0 means no UV
    normal: u32, // 0 means no normal
};

pub const ObjParser = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    file: ?std.Io.File = null,
    file_bytes: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_path: []const u8) !ObjParser {
        const file = try dir.openFile(io, file_path, .{});
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
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

        if (self.file) |obj_file| {
            var read_buf: [8192]u8 = undefined;
            var file_reader = obj_file.reader(self.io.?, &read_buf);
            const reader = &file_reader.interface;

            while (true) {
                const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
                    error.StreamTooLong => return error.StreamTooLong,
                    else => return error.ReadFailed,
                };
                const line_raw = maybe_line orelse break;
                const line = std.mem.trimEnd(u8, line_raw, &.{'\r'});
                try parseLine(
                    allocator,
                    line,
                    positions.items,
                    normals.items,
                    uvs.items,
                    &positions,
                    &normals,
                    &uvs,
                    &vertices,
                    &indices,
                    &vertex_map,
                );
            }
        } else {
            var lines = std.mem.splitScalar(u8, self.file_bytes, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, &.{'\r'});
                try parseLine(
                    allocator,
                    line,
                    positions.items,
                    normals.items,
                    uvs.items,
                    &positions,
                    &normals,
                    &uvs,
                    &vertices,
                    &indices,
                    &vertex_map,
                );
            }
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
        if (self.file) |file| {
            file.close(self.io.?);
        }
    }
};

fn parseLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    positions_items: [][3]f32,
    normals_items: [][3]f32,
    uvs_items: [][2]f32,
    positions: *std.ArrayList([3]f32),
    normals: *std.ArrayList([3]f32),
    uvs: *std.ArrayList([2]f32),
    vertices: *std.ArrayList(RawVertex),
    indices: *std.ArrayList(u32),
    vertex_map: *std.AutoHashMap(VertexKey, u32),
) ObjParseError!void {
    if (line.len == 0) {
        return;
    }

    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const prefix = tokens.next() orelse return;

    if (prefix[0] == '#') {
        return;
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
            positions_items,
            normals_items,
            uvs_items,
            vertices,
            indices,
            vertex_map,
        );
    }
    // Skip: mtllib, usemtl, s, g, o, and anything else
}

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
