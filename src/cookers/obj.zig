const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const OBJCooker = @import("../obj/cook.zig").OBJCooker;

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
    var obj_cooker = try OBJCooker.init(allocator, io, source_dir, file_path);
    defer obj_cooker.deinit();
    try obj_cooker.cook(allocator, writer);
}
