const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GltfDocument = @import("../parsers/gltf/document.zig").GltfDocument;
const CookedModel = @import("../parsers/gltf/model.zig").CookedModel;

pub fn cooker() Cooker {
    return .{ .cook_fn = cookGltf, .asset_type = .mesh };
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

    var model = try CookedModel.build(allocator, &document.gltf.value, document.buffers);
    defer model.deinit();
    try ZMesh.write(writer, model.parts);
}
