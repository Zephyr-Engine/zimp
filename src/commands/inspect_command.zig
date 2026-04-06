const std = @import("std");

const log = @import("../logger.zig");

pub const InspectError = error{
    NotEnoughArguments,
    FileNotFound,
};

pub const InspectCommand = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn parseFromArgs(io: std.Io, args: []const [:0]const u8) InspectError!InspectCommand {
        const cwd = std.Io.Dir.cwd();

        if (args.len < 3) {
            log.err("inspect: not enough arguments (got {d}, need at least 3). Usage: zimp inspect <file_path>", .{args.len});
            return InspectError.NotEnoughArguments;
        }

        const file = cwd.openFile(io, args[2], .{}) catch |err| {
            log.err("inspect: failed to open file '{s}': {s}. Ensure the file exists and has the correct permissions", .{ args[2], @errorName(err) });
            return InspectError.FileNotFound;
        };

        return .{
            .file = file,
            .io = io,
        };
    }

    pub fn run(_: InspectCommand) !void {
        log.info("Running inspect command", .{});
    }

    pub fn deinit(self: InspectCommand) void {
        self.file.close(self.io);
    }
};

const testing = std.testing;

test "InspectCommand.parseFromArgs errors with NotEnoughArguments when no file provided" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect" };
    const result = InspectCommand.parseFromArgs(testing.io, args);
    try testing.expectError(InspectError.NotEnoughArguments, result);
}

test "InspectCommand.parseFromArgs errors with FileNotFound for nonexistent file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "nonexistent_file_abc123.txt" };
    const result = InspectCommand.parseFromArgs(testing.io, args);
    try testing.expectError(InspectError.FileNotFound, result);
}

test "InspectCommand.parseFromArgs succeeds with valid file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.file.handle != 0);
}

test "InspectCommand.run executes without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.io, args);
    defer cmd.deinit();
    try cmd.run();
}

test "InspectCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.io, args);
    cmd.deinit();
}
