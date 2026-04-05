const std = @import("std");

const logger = @import("logger.zig").logger;

const Command = @import("commands/command.zig").Command;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        logger.err("Not enough arguments, must provide a command of 'cook', 'pack', or 'inspect'", .{});
        return;
    }

    const command = Command.parse(init.gpa, init.io, args) catch |err| {
        logger.err("Failed to parse command: {s}", .{@errorName(err)});
        return;
    };

    try command.run();
}
