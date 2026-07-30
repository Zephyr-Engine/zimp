const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;
const zmesh = @import("../formats/zmesh.zig");
const ObjParser = @import("../parsers/obj/obj_parser.zig").ObjParser;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;

pub fn cooker() Cooker {
    return .{ .cook_fn = cookObj, .asset_type = .mesh };
}

fn cookObj(input: *const CookInput) !void {
    var parser = ObjParser{ .allocator = input.allocator, .file_bytes = input.bytes };
    defer parser.deinit();

    var raw_mesh = try parser.parse(input.allocator);
    defer input.allocator.free(raw_mesh.vertices);
    defer input.allocator.free(raw_mesh.indices);
    defer input.allocator.free(raw_mesh.submeshes);

    var cooked_mesh = try CookedMesh.cook(input.allocator, &raw_mesh);
    defer cooked_mesh.deinit(input.allocator);

    const parts = [_]struct {
        mesh: CookedMesh,
        transform: zmesh.Transform,
    }{.{
        .mesh = cooked_mesh,
        .transform = zmesh.identity_transform,
    }};
    try zmesh.ZMesh.write(input.writer, &parts);
}
