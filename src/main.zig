const std = @import("std");

const SubCommand = @import("subcommand.zig").SubCommand;

const Config = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.log.err("Not enough arguments, must provide a command of 'cook', 'pack', or 'inspect'", .{});
        return;
    }

    const command = SubCommand.parse(init.io, args) orelse {
        std.log.err("Invalid argument, must provide a command of 'cook', 'pack', or 'inspect'", .{});
        return;
    };

    try command.run();
}
