const std = @import("std");

const log = @import("../logger.zig");
const logger = log.logger;
const logError = log.logError;

pub const PackError = error{
    NotEnoughArguments,
    SourceDirNotFound,
    OutputDirNotFound,
};

pub const PackCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    io: std.Io,

    pub fn parseFromArgs(io: std.Io, args: []const [:0]const u8) PackError!PackCommand {
        const cwd = std.Io.Dir.cwd();
        var command: PackCommand = .{
            .source = cwd,
            .output = cwd,
            .io = io,
        };

        if (args.len < 6) {
            logError("pack: not enough arguments (got {d}, need at least 6). Usage: zimp pack --source <source_dir> --output <output_dir>", .{args.len});
            return PackError.NotEnoughArguments;
        }

        var i: usize = 2;
        while (i < args.len) {
            if (std.mem.eql(u8, "--source", args[i])) {
                command.source = std.Io.Dir.openDir(cwd, io, args[i + 1], .{ .iterate = true }) catch |err| {
                    logError("pack: failed to open source directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ args[i + 1], @errorName(err) });
                    return PackError.SourceDirNotFound;
                };
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                command.output = std.Io.Dir.openDir(cwd, io, args[i + 1], .{ .iterate = true }) catch |err| {
                    logError("pack: failed to open output directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ args[i + 1], @errorName(err) });
                    return PackError.OutputDirNotFound;
                };
                i += 1;
            }

            i += 1;
        }

        return command;
    }

    pub fn run(_: PackCommand) !void {
        logger.info("Running pack command", .{});
    }

    pub fn deinit(self: PackCommand) void {
        self.source.close(self.io);
        self.output.close(self.io);
    }
};

const testing = std.testing;

test "PackCommand.parseFromArgs errors with NotEnoughArguments when no flags provided" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack" };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expectError(PackError.NotEnoughArguments, result);
}

test "PackCommand.parseFromArgs errors with NotEnoughArguments with only --source" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expectError(PackError.NotEnoughArguments, result);
}

test "PackCommand.parseFromArgs errors with NotEnoughArguments with only --output" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--output", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expectError(PackError.NotEnoughArguments, result);
}

test "PackCommand.parseFromArgs errors with SourceDirNotFound for nonexistent source" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", "nonexistent_dir_abc123", "--output", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expectError(PackError.SourceDirNotFound, result);
}

test "PackCommand.parseFromArgs errors with OutputDirNotFound for nonexistent output" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "nonexistent_dir_abc123" };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expectError(PackError.OutputDirNotFound, result);
}

test "PackCommand.parseFromArgs succeeds with valid args" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const cmd = try PackCommand.parseFromArgs(testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.source.handle != 0);
    try testing.expect(cmd.output.handle != 0);
}

test "PackCommand.parseFromArgs accepts flags in any order" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--output", ".", "--source", "." };
    const cmd = try PackCommand.parseFromArgs(testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.source.handle != 0);
    try testing.expect(cmd.output.handle != 0);
}

test "PackCommand.run executes without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const cmd = try PackCommand.parseFromArgs(testing.io, args);
    defer cmd.deinit();
    try cmd.run();
}

test "PackCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const cmd = try PackCommand.parseFromArgs(testing.io, args);
    cmd.deinit();
}
