const std = @import("std");

const log = @import("logger.zig");
const logError = log.logError;

const Command = @import("commands/command.zig").Command;

test {
    _ = @import("commands/command.zig");
}

const Config = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        logError("Not enough arguments, must provide a command of 'cook', 'pack', or 'inspect'", .{});
        return;
    }

    const command = Command.parse(init.io, args) catch |err| {
        logError("Failed to parse command: {s}", .{@errorName(err)});
        return;
    };

    try command.run();
}
