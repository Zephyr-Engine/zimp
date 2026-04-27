const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GltfDocument = @import("../parsers/gltf/document.zig").GltfDocument;
const GltfMesh = @import("../parsers/gltf/mesh.zig").GltfMesh;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;

pub fn cooker() Cooker {
    return .{ .cookFn = cookGltf, .asset_type = .mesh };
}

fn cookGltf(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    var document = try GltfDocument.loadGltf(allocator, io, source_dir, file_path);
    defer document.deinit();

    for (0..document.gltf.value.meshes.len) |i| {
        var gltf_mesh = try GltfMesh.buildMesh(allocator, &document.gltf.value, i, document.buffers);
        defer gltf_mesh.deinit();

        var cooked_mesh = try CookedMesh.cook(allocator, &gltf_mesh.raw);
        defer cooked_mesh.deinit(allocator);

        try ZMesh.write(writer, cooked_mesh);
    }
}
