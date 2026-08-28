const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zmesh = @import("../formats/zmesh.zig");

const SUBMESH_ENTRY_SIZE: u64 = @sizeOf(u32) * 2 + @sizeOf(u16) * 2;

fn inspectZmesh(allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
    var model = try zmesh.read(allocator, reader);
    defer model.deinit(allocator);

    log.info("zmesh v{d}", .{zmesh.ZMESH_VERSION});
    log.info("Material slots: {d}", .{model.material_slots.len});
    for (model.material_slots, 0..) |path, i| {
        log.info("  [{d}] {s}", .{ i, path });
    }
    log.info("Mesh parts: {d}", .{model.parts.len});

    var total_file_size: u64 = zmesh.MAGIC.len + @sizeOf(u32) * 2 + @sizeOf(u16);
    for (model.material_slots) |path| total_file_size += @sizeOf(u16) + path.len;

    for (model.parts, 0..) |part, i| {
        total_file_size += @sizeOf(zmesh.Transform);
        total_file_size += inspectPart(i, part);
    }

    log.info("", .{});
    var total_buf: [16]u8 = undefined;
    log.info("Model file size: {s}", .{fmt.formatBytes(&total_buf, total_file_size)});
}

fn inspectPart(index: usize, part: zmesh.ZMesh.Part) u64 {
    const mesh = part.mesh;
    const index_format = if (mesh.indices_u16 != null) "u16" else "u32";

    log.info("", .{});
    log.info("Part {d}:", .{index});
    log.info("  Translation: [{d:.4}, {d:.4}, {d:.4}]", .{ part.transform[12], part.transform[13], part.transform[14] });
    log.info("  Vertices:    {d}", .{mesh.vertex_count});
    log.info("  Indices:     {d}", .{mesh.index_count});
    log.info("  Triangles:   {d}", .{mesh.index_count / 3});
    log.info("  Index fmt:   {s}", .{index_format});

    log.info("", .{});
    log.info("Vertex Streams:", .{});
    log.info("  positions    {d} x [3]f32", .{mesh.positions.len});
    if (mesh.normals) |values| log.info("  normals      {d} x [2]i16", .{values.len});
    if (mesh.tangents) |values| log.info("  tangents     {d} x [4]f16", .{values.len});
    if (mesh.uv0) |values| log.info("  uv0          {d} x [2]u16", .{values.len});
    if (mesh.uv1) |values| log.info("  uv1          {d} x [2]u16", .{values.len});
    if (mesh.joint_indices) |values| log.info("  joints       {d} x [4]u16", .{values.len});
    if (mesh.joint_weights) |values| log.info("  weights      {d} x [4]f16", .{values.len});

    log.info("", .{});
    log.info("AABB:", .{});
    log.info("  min: [{d:.4}, {d:.4}, {d:.4}]", .{ mesh.aabb_min[0], mesh.aabb_min[1], mesh.aabb_min[2] });
    log.info("  max: [{d:.4}, {d:.4}, {d:.4}]", .{ mesh.aabb_max[0], mesh.aabb_max[1], mesh.aabb_max[2] });

    if (mesh.uv0 != null) {
        log.info("", .{});
        log.info("UV0 Bounds:", .{});
        log.info("  min:   [{d:.4}, {d:.4}]", .{ mesh.uv0_min[0], mesh.uv0_min[1] });
        log.info("  scale: [{d:.4}, {d:.4}]", .{ mesh.uv0_scale[0], mesh.uv0_scale[1] });
    }

    log.info("", .{});
    log.info("Submeshes ({d}):", .{mesh.submeshes.len});
    log.info("  {s: >5}  {s: >12}  {s: >12}  {s: >10}  {s: >8}", .{ "index", "index_offset", "index_count", "triangles", "material" });
    log.info("  {s}", .{"-" ** 55});
    for (mesh.submeshes, 0..) |submesh, i| {
        log.info("  {d: >5}  {d: >12}  {d: >12}  {d: >10}  {d: >8}", .{
            i,
            submesh.index_offset,
            submesh.index_count,
            submesh.index_count / 3,
            submesh.material_index,
        });
    }

    var vertex_bytes: u64 = mesh.positions.len * @sizeOf([3]f32);
    if (mesh.normals) |values| vertex_bytes += values.len * @sizeOf([2]i16);
    if (mesh.tangents) |values| vertex_bytes += values.len * @sizeOf([4]f16);
    if (mesh.uv0) |values| vertex_bytes += values.len * @sizeOf([2]u16);
    if (mesh.uv1) |values| vertex_bytes += values.len * @sizeOf([2]u16);
    if (mesh.joint_indices) |values| vertex_bytes += values.len * @sizeOf([4]u16);
    if (mesh.joint_weights) |values| vertex_bytes += values.len * @sizeOf([4]f16);

    const index_bytes: u64 = if (mesh.indices_u16) |values|
        values.len * @sizeOf(u16)
    else if (mesh.indices_u32) |values|
        values.len * @sizeOf(u32)
    else
        0;
    const index_padding = (4 - (index_bytes % 4)) % 4;
    const submesh_bytes: u64 = mesh.submeshes.len * SUBMESH_ENTRY_SIZE;
    const total = zmesh.HEADER_SIZE + vertex_bytes + index_bytes + index_padding + submesh_bytes;

    log.info("", .{});
    log.info("File Size Summary:", .{});
    var header_buf: [16]u8 = undefined;
    var vertex_buf: [16]u8 = undefined;
    var index_buf: [16]u8 = undefined;
    var submesh_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    log.info("  Header:         {s: >10}", .{fmt.formatBytes(&header_buf, zmesh.HEADER_SIZE)});
    log.info("  Vertex streams: {s: >10}", .{fmt.formatBytes(&vertex_buf, vertex_bytes)});
    log.info("  Index buffer:   {s: >10}", .{fmt.formatBytes(&index_buf, index_bytes + index_padding)});
    log.info("  Submesh table:  {s: >10}", .{fmt.formatBytes(&submesh_buf, submesh_bytes)});
    log.info("  Total:          {s: >10}", .{fmt.formatBytes(&total_buf, total)});
    return total;
}

pub fn inspector() FormatInspector {
    return .{ .inspect_fn = inspectZmesh };
}

test "inspectZmesh uses the format reader" {
    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zmesh.writeTestZmeshFile(&writer);

    var reader = std.Io.Reader.fixed(file_buf[0..writer.end]);
    try inspectZmesh(std.testing.allocator, &reader);
}
