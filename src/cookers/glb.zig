const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GLBFile = @import("../parsers/gltf/glb_parser.zig").GLBFile;
const Gltf = @import("../parsers/gltf/gltf_json_parser.zig").Gltf;
const GltfMesh = @import("../parsers/gltf/mesh.zig").GltfMesh;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;
const file_read = @import("../shared/file_read.zig");

pub fn cooker() Cooker {
    return .{ .cookFn = cookGlb, .asset_type = .mesh };
}

fn cookGlb(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    const glb_file = try GLBFile.parse(allocator, file_result.bytes);
    defer allocator.destroy(glb_file);

    var gltf = try Gltf.parse(glb_file.json, allocator);
    defer gltf.deinit();

    for (0..gltf.value.meshes.len) |i| {
        var gltf_mesh = try GltfMesh.buildMesh(allocator, &gltf.value, i, glb_file.bin);
        defer gltf_mesh.deinit();

        var cooked_mesh = try CookedMesh.cook(allocator, &gltf_mesh.raw);
        defer cooked_mesh.deinit(allocator);

        try ZMesh.write(writer, cooked_mesh);
    }
}
