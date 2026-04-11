const std = @import("std");
const log = @import("../logger.zig");

const FormatInspector = @import("inspect.zig").FormatInspector;

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZCache };
}

fn inspectZCache(_: std.mem.Allocator, _: *std.Io.Reader) !void {
    log.info("ZCache inspector called");
}
