const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zmesh = @import("../formats/zmesh.zig");
const mesh = @import("../assets/cooked/mesh.zig");

const SUBMESH_ENTRY_SIZE: u32 = 12; // u32 index_offset + u32 index_count + u16 material_index + u16 padding

pub const InspectError = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidVertexCount,
    InvalidIndexCount,
    InvalidSubmeshCount,
};

const StreamInfo = struct {
    name: []const u8,
    element_type: []const u8,
    element_size: u32,
};

const streams = [_]StreamInfo{
    .{ .name = "positions", .element_type = "[3]f32", .element_size = @sizeOf([3]f32) },
    .{ .name = "normals", .element_type = "[2]i16", .element_size = @sizeOf([2]i16) },
    .{ .name = "tangents", .element_type = "[4]f16", .element_size = @sizeOf([4]f16) },
    .{ .name = "uv0", .element_type = "[2]u16", .element_size = @sizeOf([2]u16) },
    .{ .name = "uv1", .element_type = "[2]u16", .element_size = @sizeOf([2]u16) },
    .{ .name = "joints", .element_type = "[4]u16", .element_size = @sizeOf([4]u16) },
    .{ .name = "weights", .element_type = "[4]f16", .element_size = @sizeOf([4]f16) },
};

fn streamEnabled(flags: mesh.FormatFlags, index: usize) bool {
    return switch (index) {
        0 => true,
        1 => flags.has_normals,
        2 => flags.has_tangents,
        3 => flags.has_uv0,
        4 => flags.has_uv1,
        5 => flags.has_joints,
        6 => flags.has_weights,
        else => false,
    };
}

fn readHeader(reader: *std.Io.Reader) !zmesh.ZMeshHeader {
    const version = try reader.takeInt(u32, .little);
    if (version != zmesh.ZMESH_VERSION)
        return InspectError.UnsupportedVersion;

    const vertex_count = try reader.takeInt(u32, .little);
    if (vertex_count == 0)
        return InspectError.InvalidVertexCount;

    const index_count = try reader.takeInt(u32, .little);
    if (index_count == 0 or index_count % 3 != 0)
        return InspectError.InvalidIndexCount;

    const index_format: mesh.IndexFormat = @enumFromInt(try reader.takeInt(u8, .little));
    const format_flags: mesh.FormatFlags = @bitCast(try reader.takeInt(u8, .little));

    var aabb_min: [3]f32 = undefined;
    var aabb_max: [3]f32 = undefined;
    for (0..3) |i| aabb_min[i] = @bitCast(try reader.takeInt(u32, .little));
    for (0..3) |i| aabb_max[i] = @bitCast(try reader.takeInt(u32, .little));

    const submesh_count = try reader.takeInt(u16, .little);
    if (submesh_count == 0)
        return InspectError.InvalidSubmeshCount;

    const submesh_table_offset = try reader.takeInt(u32, .little);
    const lod_count = try reader.takeInt(u16, .little);
    const lod_table_offset = try reader.takeInt(u32, .little);

    return .{
        .version = version,
        .vertex_count = vertex_count,
        .index_count = index_count,
        .index_format = index_format,
        .format_flags = format_flags,
        .aabb = .{ .min = aabb_min, .max = aabb_max },
        .submesh_count = submesh_count,
        .submesh_table_offset = submesh_table_offset,
        .lod_count = lod_count,
        .lod_table_offset = lod_table_offset,
    };
}

fn inspectZmesh(_: std.mem.Allocator, reader: *std.Io.Reader) !void {
    const header = try readHeader(reader);
    const flags = header.format_flags;

    log.info("zmesh v{d}", .{header.version});
    log.info("  Vertices:  {d}", .{header.vertex_count});
    log.info("  Indices:   {d}", .{header.index_count});
    log.info("  Triangles: {d}", .{header.index_count / 3});
    log.info("  Index fmt: {s}", .{switch (header.index_format) {
        .u16 => "u16",
        .u32 => "u32",
    }});

    log.info("", .{});
    log.info("Vertex Streams:", .{});
    log.info("  positions: enabled", .{});
    inline for (.{
        .{ "normals", flags.has_normals },
        .{ "tangents", flags.has_tangents },
        .{ "uv0", flags.has_uv0 },
        .{ "uv1", flags.has_uv1 },
        .{ "joints", flags.has_joints },
        .{ "weights", flags.has_weights },
    }) |entry| {
        if (entry[1]) {
            log.info("  {s}: enabled", .{entry[0]});
        } else {
            log.info("  {s}: \xe2\x80\x94", .{entry[0]});
        }
    }

    log.info("", .{});
    log.info("AABB:", .{});
    log.info("  min:    [{d:.4}, {d:.4}, {d:.4}]", .{ header.aabb.min[0], header.aabb.min[1], header.aabb.min[2] });
    log.info("  max:    [{d:.4}, {d:.4}, {d:.4}]", .{ header.aabb.max[0], header.aabb.max[1], header.aabb.max[2] });

    const extent: [3]f32 = .{
        header.aabb.max[0] - header.aabb.min[0],
        header.aabb.max[1] - header.aabb.min[1],
        header.aabb.max[2] - header.aabb.min[2],
    };
    const center: [3]f32 = .{
        (header.aabb.min[0] + header.aabb.max[0]) / 2.0,
        (header.aabb.min[1] + header.aabb.max[1]) / 2.0,
        (header.aabb.min[2] + header.aabb.max[2]) / 2.0,
    };
    log.info("  extent: [{d:.4}, {d:.4}, {d:.4}]", .{ extent[0], extent[1], extent[2] });
    log.info("  center: [{d:.4}, {d:.4}, {d:.4}]", .{ center[0], center[1], center[2] });

    log.info("", .{});
    log.info("Stream Layout:", .{});
    log.info("  {s: <12} {s: <10} {s: >6}  {s: >8}  {s: >10}", .{ "stream", "type", "elem", "offset", "size" });
    log.info("  {s}", .{"-" ** 52});

    var offset: u32 = zmesh.HEADER_SIZE;
    var total_stream_size: u32 = 0;

    for (streams, 0..) |stream, i| {
        if (!streamEnabled(flags, i)) continue;

        const stream_size = stream.element_size * header.vertex_count;
        var size_buf: [16]u8 = undefined;
        log.info("  {s: <12} {s: <10} {d: >4} B  {d: >6} B  {s: >10}", .{
            stream.name,
            stream.element_type,
            stream.element_size,
            offset,
            fmt.formatBytes(&size_buf, stream_size),
        });
        offset += stream_size;
        total_stream_size += stream_size;
    }

    const index_elem_size: u32 = switch (header.index_format) {
        .u16 => 2,
        .u32 => 4,
    };
    const index_buffer_size: u32 = header.index_count * index_elem_size;
    const index_padding: u32 = (4 - (index_buffer_size % 4)) % 4;

    log.info("", .{});
    log.info("Index Buffer:", .{});
    log.info("  Format: {s}", .{switch (header.index_format) {
        .u16 => "u16",
        .u32 => "u32",
    }});
    log.info("  Offset: {d} B", .{offset});
    var idx_size_buf: [16]u8 = undefined;
    log.info("  Size:   {s}", .{fmt.formatBytes(&idx_size_buf, index_buffer_size)});
    if (index_padding > 0) {
        log.info("  Padding: {d} B (4-byte alignment)", .{index_padding});
    }
    offset += index_buffer_size + index_padding;

    const skip_bytes = total_stream_size + index_buffer_size + index_padding;
    try reader.discardAll(skip_bytes);

    log.info("", .{});
    log.info("Submeshes ({d}):", .{header.submesh_count});
    log.info("  {s: >5}  {s: >12}  {s: >12}  {s: >10}  {s: >8}", .{ "index", "index_offset", "index_count", "triangles", "material" });
    log.info("  {s}", .{"-" ** 52});

    for (0..header.submesh_count) |i| {
        const sub_index_offset = try reader.takeInt(u32, .little);
        const sub_index_count = try reader.takeInt(u32, .little);
        const material_index = try reader.takeInt(u16, .little);
        _ = try reader.takeInt(u16, .little); // padding

        log.info("  {d: >5}  {d: >12}  {d: >12}  {d: >10}  {d: >8}", .{
            i,
            sub_index_offset,
            sub_index_count,
            sub_index_count / 3,
            material_index,
        });
    }

    if (header.lod_count > 0) {
        log.info("", .{});
        log.info("LODs ({d}):", .{header.lod_count});
        // TODO: read and print LOD table when format is defined
    }

    const submesh_table_size: u32 = @as(u32, header.submesh_count) * SUBMESH_ENTRY_SIZE;
    const expected_file_size: u32 = zmesh.HEADER_SIZE + total_stream_size + index_buffer_size + index_padding + submesh_table_size;

    log.info("", .{});
    log.info("File Size Summary:", .{});

    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    var buf3: [16]u8 = undefined;
    var buf4: [16]u8 = undefined;
    var buf5: [16]u8 = undefined;

    log.info("  Header:         {s: >10}", .{fmt.formatBytes(&buf1, zmesh.HEADER_SIZE)});
    log.info("  Vertex streams: {s: >10}", .{fmt.formatBytes(&buf2, total_stream_size)});
    log.info("  Index buffer:   {s: >10}", .{fmt.formatBytes(&buf3, index_buffer_size + index_padding)});
    log.info("  Submesh table:  {s: >10}", .{fmt.formatBytes(&buf4, submesh_table_size)});
    log.info("  Total:          {s: >10}", .{fmt.formatBytes(&buf5, expected_file_size)});

    if (header.submesh_table_offset != zmesh.HEADER_SIZE + total_stream_size + index_buffer_size + index_padding) {
        log.warn("Submesh table offset mismatch: header says {d}, computed {d}", .{
            header.submesh_table_offset,
            zmesh.HEADER_SIZE + total_stream_size + index_buffer_size + index_padding,
        });
    }
}

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZmesh };
}

const testing = std.testing;

test "inspector returns a valid FormatInspector" {
    const insp = inspector();
    try testing.expectEqual(@as(*const fn (std.mem.Allocator, *std.Io.Reader) anyerror!void, inspectZmesh), insp.inspectFn);
}

test "inspector can be called through FormatInspector trait" {
    const insp = inspector();

    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try writeTestZmesh(&writer, .{});

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try insp.inspect(testing.allocator, &reader);
}

test "readHeader parses a valid zmesh header" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try writeTestZmesh(&writer, .{});

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    const header = try readHeader(&reader);

    try testing.expectEqual(zmesh.ZMESH_VERSION, header.version);
    try testing.expectEqual(@as(u32, 3), header.vertex_count);
    try testing.expectEqual(@as(u32, 3), header.index_count);
    try testing.expectEqual(mesh.IndexFormat.u16, header.index_format);
    try testing.expect(header.format_flags.has_normals);
    try testing.expect(header.format_flags.has_uv0);
    try testing.expect(!header.format_flags.has_tangents);
    try testing.expectEqual(@as(u16, 1), header.submesh_count);
}

test "readHeader returns UnsupportedVersion for wrong version" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);

    try writer.writeAll(zmesh.MAGIC);
    try writer.writeInt(u32, 999, .little);
    try writer.writeAll(&(.{0} ** 50));

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try testing.expectError(InspectError.UnsupportedVersion, readHeader(&reader));
}

test "readHeader returns InvalidVertexCount for zero vertices" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);

    try writer.writeAll(zmesh.MAGIC);
    try writer.writeInt(u32, zmesh.ZMESH_VERSION, .little);
    try writer.writeInt(u32, 0, .little); // vertex_count = 0
    try writer.writeAll(&(.{0} ** 50));

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try testing.expectError(InspectError.InvalidVertexCount, readHeader(&reader));
}

test "readHeader returns InvalidIndexCount for zero indices" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);

    try writer.writeAll(zmesh.MAGIC);
    try writer.writeInt(u32, zmesh.ZMESH_VERSION, .little);
    try writer.writeInt(u32, 3, .little); // vertex_count
    try writer.writeInt(u32, 0, .little); // index_count = 0
    try writer.writeAll(&(.{0} ** 50));

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try testing.expectError(InspectError.InvalidIndexCount, readHeader(&reader));
}

test "readHeader returns InvalidIndexCount for indices not divisible by 3" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);

    try writer.writeAll(zmesh.MAGIC);
    try writer.writeInt(u32, zmesh.ZMESH_VERSION, .little);
    try writer.writeInt(u32, 3, .little); // vertex_count
    try writer.writeInt(u32, 5, .little); // index_count = 5 (not divisible by 3)
    try writer.writeAll(&(.{0} ** 50));

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try testing.expectError(InspectError.InvalidIndexCount, readHeader(&reader));
}

test "readHeader returns InvalidSubmeshCount for zero submeshes" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);

    try writer.writeAll(zmesh.MAGIC);
    try writer.writeInt(u32, zmesh.ZMESH_VERSION, .little);
    try writer.writeInt(u32, 3, .little); // vertex_count
    try writer.writeInt(u32, 3, .little); // index_count
    try writer.writeInt(u8, 0, .little); // index_format (u16)
    try writer.writeInt(u8, 0, .little); // format_flags
    for (0..6) |_| try writer.writeInt(u32, 0, .little); // aabb
    try writer.writeInt(u16, 0, .little); // submesh_count = 0
    try writer.writeAll(&(.{0} ** 20));

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try testing.expectError(InspectError.InvalidSubmeshCount, readHeader(&reader));
}

test "readHeader parses AABB correctly" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try writeTestZmesh(&writer, .{ .aabb_min = .{ -1.5, -2.0, -3.0 }, .aabb_max = .{ 4.0, 5.0, 6.0 } });

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    const header = try readHeader(&reader);

    try testing.expectEqual([3]f32{ -1.5, -2.0, -3.0 }, header.aabb.min);
    try testing.expectEqual([3]f32{ 4.0, 5.0, 6.0 }, header.aabb.max);
}

test "inspectZmesh runs without error on valid zmesh" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try writeTestZmesh(&writer, .{});

    var reader = std.Io.Reader.fixed(file_buf[5..writer.end]);
    try inspectZmesh(testing.allocator, &reader);
}

test "streamEnabled: positions always enabled" {
    const flags = mesh.FormatFlags{};
    try testing.expect(streamEnabled(flags, 0));
}

test "streamEnabled: normals flag controls index 1" {
    try testing.expect(!streamEnabled(mesh.FormatFlags{}, 1));
    try testing.expect(streamEnabled(mesh.FormatFlags{ .has_normals = true }, 1));
}

test "streamEnabled: tangents flag controls index 2" {
    try testing.expect(!streamEnabled(mesh.FormatFlags{}, 2));
    try testing.expect(streamEnabled(mesh.FormatFlags{ .has_tangents = true }, 2));
}

test "streamEnabled: uv0 flag controls index 3" {
    try testing.expect(!streamEnabled(mesh.FormatFlags{}, 3));
    try testing.expect(streamEnabled(mesh.FormatFlags{ .has_uv0 = true }, 3));
}

test "streamEnabled: out of range returns false" {
    try testing.expect(!streamEnabled(mesh.FormatFlags{}, 99));
}

const TestZmeshOpts = struct {
    vertex_count: u32 = 3,
    index_count: u32 = 3,
    index_format: mesh.IndexFormat = .u16,
    format_flags: mesh.FormatFlags = .{ .has_normals = true, .has_uv0 = true },
    aabb_min: [3]f32 = .{ 0, 0, 0 },
    aabb_max: [3]f32 = .{ 1, 1, 0 },
    submesh_count: u16 = 1,
};

fn writeTestZmesh(writer: *std.Io.Writer, opts: TestZmeshOpts) !void {
    const flags = opts.format_flags;

    var vertex_data_size: u32 = opts.vertex_count * @sizeOf([3]f32);
    if (flags.has_normals) vertex_data_size += opts.vertex_count * @sizeOf([2]i16);
    if (flags.has_tangents) vertex_data_size += opts.vertex_count * @sizeOf([4]f16);
    if (flags.has_uv0) vertex_data_size += opts.vertex_count * @sizeOf([2]u16);
    if (flags.has_uv1) vertex_data_size += opts.vertex_count * @sizeOf([2]u16);
    if (flags.has_joints) vertex_data_size += opts.vertex_count * @sizeOf([4]u16);
    if (flags.has_weights) vertex_data_size += opts.vertex_count * @sizeOf([4]f16);

    const idx_size: u32 = switch (opts.index_format) {
        .u16 => 2,
        .u32 => 4,
    };
    const index_data_size = opts.index_count * idx_size;
    const index_padding = (4 - (index_data_size % 4)) % 4;
    const submesh_table_offset = zmesh.HEADER_SIZE + vertex_data_size + index_data_size + index_padding;

    try writer.writeAll(zmesh.MAGIC);
    try writer.writeInt(u32, zmesh.ZMESH_VERSION, .little);
    try writer.writeInt(u32, opts.vertex_count, .little);
    try writer.writeInt(u32, opts.index_count, .little);
    try writer.writeInt(u8, @intFromEnum(opts.index_format), .little);
    try writer.writeInt(u8, @bitCast(flags), .little);
    for (opts.aabb_min) |v| try writer.writeInt(u32, @bitCast(v), .little);
    for (opts.aabb_max) |v| try writer.writeInt(u32, @bitCast(v), .little);
    try writer.writeInt(u16, opts.submesh_count, .little);
    try writer.writeInt(u32, submesh_table_offset, .little);
    try writer.writeInt(u16, 0, .little); // lod_count
    try writer.writeInt(u32, 0, .little); // lod_table_offset

    for (0..vertex_data_size) |_| try writer.writeInt(u8, 0, .little);
    for (0..index_data_size) |_| try writer.writeInt(u8, 0, .little);
    for (0..index_padding) |_| try writer.writeInt(u8, 0, .little);
    for (0..opts.submesh_count) |_| {
        try writer.writeInt(u32, 0, .little); // index_offset
        try writer.writeInt(u32, opts.index_count, .little); // index_count
        try writer.writeInt(u16, 0, .little); // material_index
        try writer.writeInt(u16, 0, .little); // padding
    }
}
