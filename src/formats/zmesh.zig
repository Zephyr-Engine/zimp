const std = @import("std");
const logger = @import("../logger.zig");
const mesh = @import("../assets/cooked/mesh.zig");

pub const EXTENSION = ".zmesh";

pub const ZMESH_VERSION: u32 = 1;

pub const ZMeshHeader = struct {
    magic: [4]u8 = "ZMESH",
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
        return ZMeshHeader{
            .vertex_count = cooked_mesh.vertices.len,
            .index_count = cooked_mesh.indices.len(),
            .index_format = cooked_mesh.indices,
            .format_flags = cooked_mesh.format_flags,
            .aabb = cooked_mesh.aabb,
            .submesh_count = @intCast(cooked_mesh.submeshes.len),
            .submesh_table_offset = 0, // TODO: calculate this based on header size and vertex/index data sizes
            .lod_count = 0, // TODO implement LOD
            .lod_table_offset = 0, // TODO: implement LOD & calculate this based on header size, vertex/index data sizes, and submesh table size
        };
    }
};

pub const ZMesh = struct {
    pub fn write(io: std.Io, output_dir: std.Io.Dir, filename: []const u8, cooked_mesh: mesh.CookedMesh) !void {
        output_dir.createFile(io, filename, .{}) catch |err| {
            logger.err("Failed to create file '{s}': {s}\n", .{ filename, @errorName(err) });
            return err;
        };

        _ = ZMeshHeader.init(cooked_mesh);
    }
};
