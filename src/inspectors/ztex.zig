const std = @import("std");
const FormatInspector = @import("inspect.zig").FormatInspector;

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZmesh };
}

fn inspectZmesh(_: std.mem.Allocator, _: *std.Io.Reader) !void {}
