const std = @import("std");

const log = @import("../logger.zig");

pub const PackError = error{
    NotEnoughArguments,
    SourceDirNotFound,
    OutputDirNotFound,
    MissingFlagValue,
    UnknownFlag,
    DuplicateFlag,
};

pub const PackCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    io: std.Io,

    pub fn parseFromArgs(io: std.Io, args: []const [:0]const u8) PackError!PackCommand {
        const cwd = std.Io.Dir.cwd();
        var source_arg: ?[]const u8 = null;
        var output_arg: ?[]const u8 = null;

        var i: usize = 2;
        while (i < args.len) {
            if (std.mem.eql(u8, "--source", args[i])) {
                if (source_arg != null) return PackError.DuplicateFlag;
                if (i + 1 >= args.len) return PackError.MissingFlagValue;
                source_arg = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                if (output_arg != null) return PackError.DuplicateFlag;
                if (i + 1 >= args.len) return PackError.MissingFlagValue;
                output_arg = args[i + 1];
                i += 1;
            } else {
                return PackError.UnknownFlag;
            }

            i += 1;
        }

        if (source_arg == null or output_arg == null) return PackError.NotEnoughArguments;

        const source = std.Io.Dir.openDir(cwd, io, source_arg.?, .{ .iterate = true }) catch |err| {
            log.err("pack: failed to open source directory '{s}': {s}", .{ source_arg.?, @errorName(err) });
            return PackError.SourceDirNotFound;
        };
        errdefer source.close(io);
        const output = std.Io.Dir.openDir(cwd, io, output_arg.?, .{ .iterate = true }) catch |err| {
            log.err("pack: failed to open output directory '{s}': {s}", .{ output_arg.?, @errorName(err) });
            return PackError.OutputDirNotFound;
        };

        return .{ .source = source, .output = output, .io = io };
    }

    pub fn run(_: PackCommand) !void {
        log.err("pack: archive packing is not implemented", .{});
        return error.PackNotImplemented;
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

test "PackCommand.run reports that packing is not implemented" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const cmd = try PackCommand.parseFromArgs(testing.io, args);
    defer cmd.deinit();
    try testing.expectError(error.PackNotImplemented, cmd.run());
}

test "PackCommand.parseFromArgs rejects a missing trailing flag value" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output" };
    try testing.expectError(PackError.MissingFlagValue, PackCommand.parseFromArgs(testing.io, args));
}

test "PackCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const cmd = try PackCommand.parseFromArgs(testing.io, args);
    cmd.deinit();
}
