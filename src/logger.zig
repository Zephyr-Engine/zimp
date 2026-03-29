const std = @import("std");
const builtin = @import("builtin");

pub const logger = std.log.scoped(.zimp);

pub fn logError(comptime fmt: []const u8, args: anytype) void {
    if (comptime !builtin.is_test) {
        logger.err(fmt, args);
    }
}
