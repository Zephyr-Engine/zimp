const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const GltfDocument = @import("../parsers/gltf/document.zig").GltfDocument;
const CookedModel = @import("../parsers/gltf/model.zig").CookedModel;

pub fn cooker() Cooker {
    return .{ .cook_fn = cookGltf, .asset_type = .mesh };
}

fn cookGltf(input: *const CookInput) !void {
    var document = try GltfDocument.loadGltfFromBytes(
        input.allocator,
        input.io,
        input.source_dir,
        input.source.path,
        input.bytes,
    );
    defer document.deinit();

    var model = try CookedModel.build(input.allocator, &document.gltf.value, document.buffers);
    defer model.deinit();
    try ZMesh.write(input.writer, model.parts);
}
