const std = @import("std");
const mesh = @import("../assets/cooked/mesh.zig");

pub const MAGIC = "ZMESH";
pub const ZMESH_VERSION: u32 = 1;

pub const HEADER_SIZE: u32 = MAGIC.len // magic
+ @sizeOf(u32) // version
+ @sizeOf(u32) // vertex_count
+ @sizeOf(u32) // index_count
+ @sizeOf(u8) // index_format
+ @sizeOf(u8) // format_flags
+ @sizeOf([3]f32) * 2 // aabb min + max
+ @sizeOf(u16) // submesh_count
+ @sizeOf(u32) // submesh_table_offset
+ @sizeOf(u16) // lod_count
+ @sizeOf(u32); // lod_table_offset

pub const ZMeshHeader = struct {
    magic: [5]u8 = MAGIC.*,
    version: u32 = ZMESH_VERSION,
    vertex_count: u32,
    index_count: u32,
    index_format: mesh.IndexFormat,
    format_flags: mesh.FormatFlags,
    aabb: mesh.AABB,
    submesh_count: u16,
    submesh_table_offset: u32,
    lod_count: u16,
    lod_table_offset: u32,

    pub fn init(cooked_mesh: mesh.CookedMesh) ZMeshHeader {
        const vertex_count: u32 = @intCast(cooked_mesh.vertices.len);
        const index_count: u32 = @intCast(cooked_mesh.indices.len());
        const flags = cooked_mesh.format_flags;
        const idx_format = cooked_mesh.indices.format();

        var vertex_data_size: u32 = vertex_count * @sizeOf([3]f32);
        if (flags.has_normals) vertex_data_size += vertex_count * @sizeOf([2]i16);
        if (flags.has_tangents) vertex_data_size += vertex_count * @sizeOf([4]f16);
        if (flags.has_uv0) vertex_data_size += vertex_count * @sizeOf([2]u16);
        if (flags.has_uv1) vertex_data_size += vertex_count * @sizeOf([2]u16);
        if (flags.has_joints) vertex_data_size += vertex_count * @sizeOf([4]u16);
        if (flags.has_weights) vertex_data_size += vertex_count * @sizeOf([4]f16);

        const index_byte_size: u32 = switch (idx_format) {
            .u16 => 2,
            .u32 => 4,
        };
        const index_data_size = index_count * index_byte_size;
        const index_padding: u32 = (4 - (index_data_size % 4)) % 4;

        return .{
            .vertex_count = vertex_count,
            .index_count = index_count,
            .index_format = idx_format,
            .format_flags = flags,
            .aabb = cooked_mesh.bounds,
            .submesh_count = @intCast(cooked_mesh.submeshes.len),
            .submesh_table_offset = HEADER_SIZE + vertex_data_size + index_data_size + index_padding,
            .lod_count = 0,
            .lod_table_offset = 0,
        };
    }

    pub fn write(self: *const ZMeshHeader, writer: *std.Io.Writer) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u32, self.version, .little);
        try writer.writeInt(u32, self.vertex_count, .little);
        try writer.writeInt(u32, self.index_count, .little);
        try writer.writeInt(u8, @intFromEnum(self.index_format), .little);
        try writer.writeInt(u8, @bitCast(self.format_flags), .little);
        for (self.aabb.min) |v| {
            try writer.writeInt(u32, @bitCast(v), .little);
        }
        for (self.aabb.max) |v| {
            try writer.writeInt(u32, @bitCast(v), .little);
        }
        try writer.writeInt(u16, self.submesh_count, .little);
        try writer.writeInt(u32, self.submesh_table_offset, .little);
        try writer.writeInt(u16, self.lod_count, .little);
        try writer.writeInt(u32, self.lod_table_offset, .little);
    }
};

pub const ZMesh = struct {
    pub fn write(writer: *std.Io.Writer, cooked_mesh: mesh.CookedMesh) !void {
        const header = ZMeshHeader.init(cooked_mesh);
        try header.write(writer);

        for (cooked_mesh.vertices) |v| {
            try writer.writeAll(std.mem.sliceAsBytes(&v.position));
        }

        if (header.format_flags.has_normals) {
            for (cooked_mesh.vertices) |v| {
                try writer.writeAll(std.mem.sliceAsBytes(&v.normal.?));
            }
        }

        if (header.format_flags.has_tangents) {
            for (cooked_mesh.vertices) |v| {
                try writer.writeAll(std.mem.sliceAsBytes(&v.tangent.?));
            }
        }

        if (header.format_flags.has_uv0) {
            for (cooked_mesh.vertices) |v| {
                try writer.writeAll(std.mem.sliceAsBytes(&v.uv0.?));
            }
        }

        if (header.format_flags.has_uv1) {
            for (cooked_mesh.vertices) |v| {
                try writer.writeAll(std.mem.sliceAsBytes(&v.uv1.?));
            }
        }

        if (header.format_flags.has_joints) {
            for (cooked_mesh.vertices) |v| {
                try writer.writeAll(std.mem.sliceAsBytes(&v.joint_indices.?));
            }
        }

        if (header.format_flags.has_weights) {
            for (cooked_mesh.vertices) |v| {
                try writer.writeAll(std.mem.sliceAsBytes(&v.joint_weights.?));
            }
        }

        if (cooked_mesh.indices.u16) |indices| {
            try writer.writeAll(std.mem.sliceAsBytes(indices));
        } else if (cooked_mesh.indices.u32) |indices| {
            try writer.writeAll(std.mem.sliceAsBytes(indices));
        }

        // Pad to 4-byte alignment
        const index_byte_size: usize = switch (header.index_format) {
            .u16 => 2,
            .u32 => 4,
        };
        const index_bytes = cooked_mesh.indices.len() * index_byte_size;
        const padding = (4 - (index_bytes % 4)) % 4;
        if (padding > 0) {
            try writer.writeAll("\x00\x00\x00"[0..padding]);
        }

        for (cooked_mesh.submeshes) |submesh| {
            try writer.writeInt(u32, submesh.index_offset, .little);
            try writer.writeInt(u32, submesh.index_count, .little);
            try writer.writeInt(u16, submesh.material_index, .little);
            try writer.writeInt(u16, 0, .little); // padding
        }
    }
};

const testing = std.testing;
const raw_mesh = @import("../assets/raw/mesh.zig");

fn makeVertex(x: f32, y: f32, z: f32) mesh.CookedVertex {
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

fn makeCookedMesh(vertices: []const mesh.CookedVertex, indices: mesh.IndexBuffer, submeshes: []const raw_mesh.RawSubmesh, flags: mesh.FormatFlags, bounds: mesh.AABB) mesh.CookedMesh {
    return .{
        .vertices = @constCast(vertices),
        .indices = indices,
        .submeshes = @constCast(submeshes),
        .format_flags = flags,
        .bounds = bounds,
        .name = null,
    };
}

fn writeToBuffer(cooked: mesh.CookedMesh) !struct { buf: [4096]u8, len: usize } {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try ZMesh.write(&writer, cooked);
    return .{ .buf = buf, .len = writer.end };
}

fn readU32(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

fn readU16(buf: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, buf[offset..][0..2], .little);
}

fn readF32(buf: []const u8, offset: usize) f32 {
    return @bitCast(readU32(buf, offset));
}

test "HEADER_SIZE equals 55" {
    try testing.expectEqual(@as(u32, 55), HEADER_SIZE);
}

test "ZMeshHeader.init sets magic and version" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqualSlices(u8, "ZMESH", &header.magic);
    try testing.expectEqual(ZMESH_VERSION, header.version);
}

test "ZMeshHeader.init sets vertex and index counts" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(@as(u32, 3), header.vertex_count);
    try testing.expectEqual(@as(u32, 3), header.index_count);
}

test "ZMeshHeader.init detects u16 index format" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(mesh.IndexFormat.u16, header.index_format);
}

test "ZMeshHeader.init detects u32 index format" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&[_]u32{0}) }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(mesh.IndexFormat.u32, header.index_format);
}

test "ZMeshHeader.init copies format flags" {
    const flags: mesh.FormatFlags = .{ .has_normals = true, .has_uv0 = true };
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, flags, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expect(header.format_flags.has_normals);
    try testing.expect(header.format_flags.has_uv0);
    try testing.expect(!header.format_flags.has_tangents);
}

test "ZMeshHeader.init copies AABB" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const bounds: mesh.AABB = .{ .min = .{ -1, -2, -3 }, .max = .{ 4, 5, 6 } };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, bounds);
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual([3]f32{ -1, -2, -3 }, header.aabb.min);
    try testing.expectEqual([3]f32{ 4, 5, 6 }, header.aabb.max);
}

test "ZMeshHeader.init sets submesh count" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const submeshes = [_]raw_mesh.RawSubmesh{
        .{ .index_offset = 0, .index_count = 3, .material_index = 0 },
        .{ .index_offset = 3, .index_count = 6, .material_index = 1 },
    };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &submeshes, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(@as(u16, 2), header.submesh_count);
}

test "submesh_table_offset with positions only and u16 indices" {
    // 3 verts × 12 bytes = 36, 3 u16 indices = 6 bytes, padding = 2
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(HEADER_SIZE + 36 + 6 + 2, header.submesh_table_offset);
}

test "submesh_table_offset with positions only and u32 indices (no padding)" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const cooked = makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&[_]u32{ 0, 1, 2 }) }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(HEADER_SIZE + 36 + 12 + 0, header.submesh_table_offset);
}

test "submesh_table_offset accounts for normals and uvs" {
    // 1 vert: positions 12 + normals 4 + uv0 4 = 20, 1 u32 index = 4
    const flags: mesh.FormatFlags = .{ .has_normals = true, .has_uv0 = true };
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&[_]u32{0}) }, &.{}, flags, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    try testing.expectEqual(HEADER_SIZE + 20 + 4, header.submesh_table_offset);
}

test "ZMeshHeader.write writes magic at offset 0" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqualSlices(u8, "ZMESH", buf[0..5]);
}

test "ZMeshHeader.write writes version at offset 5" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(ZMESH_VERSION, readU32(&buf, 5));
}

test "ZMeshHeader.write writes vertex and index counts" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1, 2 }), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });
    const header = ZMeshHeader.init(cooked);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(@as(u32, 3), readU32(&buf, 9)); // vertex_count
    try testing.expectEqual(@as(u32, 3), readU32(&buf, 13)); // index_count
}

test "ZMeshHeader.write writes index format and format flags" {
    const flags: mesh.FormatFlags = .{ .has_normals = true, .has_uv0 = true };
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, flags, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(@as(u8, 0), buf[17]); // index_format: u16 = 0
    const written_flags: mesh.FormatFlags = @bitCast(buf[18]);
    try testing.expect(written_flags.has_normals);
    try testing.expect(written_flags.has_uv0);
    try testing.expect(!written_flags.has_tangents);
}

test "ZMeshHeader.write writes AABB" {
    const bounds: mesh.AABB = .{ .min = .{ -1.5, 0, 2.5 }, .max = .{ 10, 20, 30 } };
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, bounds);
    const header = ZMeshHeader.init(cooked);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    // AABB starts at offset 19
    try testing.expectEqual(@as(f32, -1.5), readF32(&buf, 19));
    try testing.expectEqual(@as(f32, 0), readF32(&buf, 23));
    try testing.expectEqual(@as(f32, 2.5), readF32(&buf, 27));
    try testing.expectEqual(@as(f32, 10), readF32(&buf, 31));
    try testing.expectEqual(@as(f32, 20), readF32(&buf, 35));
    try testing.expectEqual(@as(f32, 30), readF32(&buf, 39));
}

test "ZMeshHeader.write total output is HEADER_SIZE bytes" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });
    const header = ZMeshHeader.init(cooked);

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try header.write(&writer);

    try testing.expectEqual(HEADER_SIZE, @as(u32, @intCast(writer.end)));
}

// ── ZMesh.write full output ──

test "ZMesh.write writes positions after header" {
    const verts = [_]mesh.CookedVertex{ makeVertex(1, 2, 3), makeVertex(4, 5, 6) };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{ 0, 1 }), .u32 = null }, &.{}, .{}, .{ .min = .{ 1, 2, 3 }, .max = .{ 4, 5, 6 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const off = HEADER_SIZE;

    try testing.expectEqual(@as(f32, 1), readF32(&buf, off));
    try testing.expectEqual(@as(f32, 2), readF32(&buf, off + 4));
    try testing.expectEqual(@as(f32, 3), readF32(&buf, off + 8));
    try testing.expectEqual(@as(f32, 4), readF32(&buf, off + 12));
    try testing.expectEqual(@as(f32, 5), readF32(&buf, off + 16));
    try testing.expectEqual(@as(f32, 6), readF32(&buf, off + 20));
}

test "ZMesh.write writes u16 indices after vertex data" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const indices = [_]u16{ 0, 1, 2 };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&indices), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const idx_off = HEADER_SIZE + 3 * 12; // 3 verts × 12 bytes

    try testing.expectEqual(@as(u16, 0), readU16(&buf, idx_off));
    try testing.expectEqual(@as(u16, 1), readU16(&buf, idx_off + 2));
    try testing.expectEqual(@as(u16, 2), readU16(&buf, idx_off + 4));
}

test "ZMesh.write writes u32 indices after vertex data" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0) };
    const indices = [_]u32{ 0, 1 };
    const cooked = makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&indices) }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0, 0 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const idx_off = HEADER_SIZE + 2 * 12;

    try testing.expectEqual(@as(u32, 0), readU32(&buf, idx_off));
    try testing.expectEqual(@as(u32, 1), readU32(&buf, idx_off + 4));
}

test "ZMesh.write pads u16 indices to 4-byte alignment" {
    // 3 u16 indices = 6 bytes, needs 2 bytes padding
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const indices = [_]u16{ 0, 1, 2 };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&indices), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const pad_off = HEADER_SIZE + 3 * 12 + 6; // after indices

    try testing.expectEqual(@as(u8, 0), buf[pad_off]);
    try testing.expectEqual(@as(u8, 0), buf[pad_off + 1]);
}

test "ZMesh.write no padding needed for even u16 index count" {
    // 2 u16 indices = 4 bytes, already aligned
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0) };
    const indices = [_]u16{ 0, 1 };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&indices), .u32 = null }, &.{}, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0, 0 } });

    const header = ZMeshHeader.init(cooked);
    const expected_size = HEADER_SIZE + 2 * 12 + 4; // no padding, no submeshes
    try testing.expectEqual(expected_size, header.submesh_table_offset);
}

test "ZMesh.write writes submesh table" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const indices = [_]u32{ 0, 1, 2 };
    const submeshes = [_]raw_mesh.RawSubmesh{
        .{ .index_offset = 0, .index_count = 3, .material_index = 7 },
    };
    const cooked = makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&indices) }, &submeshes, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const header = ZMeshHeader.init(cooked);
    const off = header.submesh_table_offset;

    try testing.expectEqual(@as(u32, 0), readU32(&buf, off)); // index_offset
    try testing.expectEqual(@as(u32, 3), readU32(&buf, off + 4)); // index_count
    try testing.expectEqual(@as(u16, 7), readU16(&buf, off + 8)); // material_index
    try testing.expectEqual(@as(u16, 0), readU16(&buf, off + 10)); // padding
}

test "ZMesh.write writes multiple submeshes" {
    const verts = [_]mesh.CookedVertex{makeVertex(0, 0, 0)};
    const indices = [_]u32{ 0, 0, 0, 0, 0, 0 };
    const submeshes = [_]raw_mesh.RawSubmesh{
        .{ .index_offset = 0, .index_count = 3, .material_index = 0 },
        .{ .index_offset = 3, .index_count = 3, .material_index = 1 },
    };
    const cooked = makeCookedMesh(&verts, .{ .u16 = null, .u32 = @constCast(&indices) }, &submeshes, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const header = ZMeshHeader.init(cooked);
    const off = header.submesh_table_offset;

    // Second submesh at offset + 12
    try testing.expectEqual(@as(u32, 3), readU32(&buf, off + 12)); // index_offset
    try testing.expectEqual(@as(u32, 3), readU32(&buf, off + 16)); // index_count
    try testing.expectEqual(@as(u16, 1), readU16(&buf, off + 20)); // material_index
}

test "ZMesh.write total size matches expected" {
    const verts = [_]mesh.CookedVertex{ makeVertex(0, 0, 0), makeVertex(1, 0, 0), makeVertex(0, 1, 0) };
    const indices = [_]u16{ 0, 1, 2 };
    const submeshes = [_]raw_mesh.RawSubmesh{
        .{ .index_offset = 0, .index_count = 3, .material_index = 0 },
    };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&indices), .u32 = null }, &submeshes, .{}, .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 0 } });

    const result = try writeToBuffer(cooked);
    // header(55) + positions(36) + indices(6) + padding(2) + submesh(12) = 111
    const expected: usize = HEADER_SIZE + 36 + 6 + 2 + 12;
    try testing.expectEqual(expected, result.len);
}

test "ZMesh.write with normals writes normal stream after positions" {
    var v = makeVertex(1, 2, 3);
    v.normal = .{ 100, -200 };
    const verts = [_]mesh.CookedVertex{v};
    const flags: mesh.FormatFlags = .{ .has_normals = true };
    const cooked = makeCookedMesh(&verts, .{ .u16 = @constCast(&[_]u16{0}), .u32 = null }, &.{}, flags, .{ .min = .{ 1, 2, 3 }, .max = .{ 1, 2, 3 } });

    const result = try writeToBuffer(cooked);
    const buf = result.buf;
    const normal_off = HEADER_SIZE + 12; // after 1 position

    const n0 = std.mem.readInt(i16, buf[normal_off..][0..2], .little);
    const n1 = std.mem.readInt(i16, buf[normal_off + 2 ..][0..2], .little);
    try testing.expectEqual(@as(i16, 100), n0);
    try testing.expectEqual(@as(i16, -200), n1);
}
