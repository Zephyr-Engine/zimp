const std = @import("std");

pub const FormatInspector = struct {
    inspectFn: *const fn (
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) anyerror!void,

    pub fn inspect(self: FormatInspector, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
        return self.inspectFn(allocator, reader);
    }
};
