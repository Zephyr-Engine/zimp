const std = @import("std");
const mesh = @import("../assets/cooked/mesh.zig");

pub const MAGIC = "ZMESH";
pub const ZMESH_VERSION: u32 = 1;

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
        return .{
            .vertex_count = @intCast(cooked_mesh.vertices.len),
            .index_count = @intCast(cooked_mesh.indices.len()),
            .index_format = cooked_mesh.indices.format(),
            .format_flags = cooked_mesh.format_flags,
            .aabb = cooked_mesh.bounds,
            .submesh_count = @intCast(cooked_mesh.submeshes.len),
            .submesh_table_offset = 0,
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
    }
};
