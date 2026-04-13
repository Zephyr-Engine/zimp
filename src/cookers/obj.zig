const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const ObjParser = @import("../parsers/obj/obj_parser.zig").ObjParser;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;

pub fn cooker() Cooker {
    return .{ .cookFn = cookObj };
}

fn cookObj(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    var parser = try ObjParser.init(allocator, io, source_dir, file_path);
    defer parser.deinit();

    var raw_mesh = try parser.parse(allocator);
    defer allocator.free(raw_mesh.vertices);
    defer allocator.free(raw_mesh.indices);
    defer allocator.free(raw_mesh.submeshes);

    var cooked_mesh = try CookedMesh.cook(allocator, &raw_mesh);
    defer cooked_mesh.deinit(allocator);

    try ZMesh.write(writer, cooked_mesh);
}
