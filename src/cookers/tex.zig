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
    _ = allocator;
    _ = io;
    _ = source_dir;
    _ = file_path;
    _ = writer;
}
