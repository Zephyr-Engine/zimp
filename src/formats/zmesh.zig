const std = @import("std");
const logger = @import("../logger.zig");
const mesh = @import("../assets/cooked/mesh.zig");

pub const EXTENSION = ".zmesh";

pub const ZMESH_VERSION: u32 = 1;

pub const ZMeshHeader = struct {
    magic: [5]u8 = "ZMESH".*,
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
            .vertex_count = @intCast(cooked_mesh.vertices.len),
            .index_count = @intCast(cooked_mesh.indices.len()),
            .index_format = cooked_mesh.indices.format(),
            .format_flags = cooked_mesh.format_flags,
            .aabb = cooked_mesh.bounds,
            .submesh_count = @intCast(cooked_mesh.submeshes.len),
            .submesh_table_offset = 0, // TODO: calculate this based on header size and vertex/index data sizes
            .lod_count = 0, // TODO implement LOD
            .lod_table_offset = 0, // TODO: implement LOD & calculate this based on header size, vertex/index data sizes, and submesh table size
        };
    }
};

pub const ZMesh = struct {
    pub fn write(allocator: std.mem.Allocator, io: std.Io, output_dir: std.Io.Dir, source_path: []const u8, cooked_mesh: mesh.CookedMesh) !void {
        const name = cooked_mesh.name orelse std.fs.path.stem(source_path);
        const filename = try std.fmt.allocPrint(allocator, "{s}" ++ EXTENSION, .{name});
        defer allocator.free(filename);

        const file = output_dir.createFile(io, filename, .{}) catch |err| {
            logger.err("Failed to create file '{s}': {s}", .{ filename, @errorName(err) });
            return err;
        };
        defer file.close(io);

        const header = ZMeshHeader.init(cooked_mesh);
        _ = header;

        // TODO: write header and mesh data using file.writer(io, &buf)
    }
};
