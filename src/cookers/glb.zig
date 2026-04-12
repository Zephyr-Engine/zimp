const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const GLBCooker = @import("../gltf/cook.zig").GLBCooker;

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
    var glb_cooker = try GLBCooker.init(allocator, io, source_dir, file_path);
    defer glb_cooker.deinit();
    try glb_cooker.cook(allocator, writer);
}
