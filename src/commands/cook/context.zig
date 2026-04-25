const std = @import("std");

pub const CookContext = struct {
    io: std.Io,
    source: std.Io.Dir,
    output: std.Io.Dir,
    output_path: []const u8,
    force: bool,
};
