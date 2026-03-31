const std = @import("std");

pub const AssetHasher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AssetHasher {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }
};
