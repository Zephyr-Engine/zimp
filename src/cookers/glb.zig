const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GLBFile = @import("../parsers/gltf/glb_parser.zig").GLBFile;
const Gltf = @import("../parsers/gltf/gltf_json_parser.zig").Gltf;
const GltfMesh = @import("../parsers/gltf/mesh.zig").GltfMesh;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;

pub fn cooker() Cooker {
    return .{ .cookFn = cookGlb };
}

fn cookGlb(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const file_bytes = try source_dir.readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(file_bytes);

    const glb_file = try GLBFile.parse(allocator, file_bytes);
    defer allocator.destroy(glb_file);

    var gltf = try Gltf.parse(glb_file.json, allocator);
    defer gltf.deinit();

    for (0..gltf.value.meshes.len) |i| {
        var gltf_mesh = try GltfMesh.buildMesh(allocator, &gltf.value, i, glb_file.bin);
        defer gltf_mesh.deinit();

        var cooked_mesh = try gltf_mesh.cook(allocator);
        defer cooked_mesh.deinit(allocator);

        try ZMesh.write(writer, cooked_mesh);
    }
}
