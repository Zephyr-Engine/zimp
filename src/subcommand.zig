const std = @import("std");
pub const SubCommand = union(enum) {
    Cook: CookCommand,
    Pack: PackCommand,
    Inspect: InspectCommand,

    pub fn parse(io: std.Io, args: []const [:0]const u8) ?SubCommand {
        if (std.mem.eql(u8, args[1], "cook")) {
            const cmd = CookCommand.parseFromArgs(io, args) orelse return null;
            return .{ .Cook = cmd };
        }

        if (std.mem.eql(u8, args[1], "pack")) {
            const cmd = PackCommand.parseFromArgs(io, args) orelse return null;
            return .{ .Pack = cmd };
        }

        if (std.mem.eql(u8, args[1], "inspect")) {
            const cmd = InspectCommand.parseFromArgs(io, args) orelse return null;
            return .{ .Inspect = cmd };
        }

        return null;
    }

    pub fn run(self: SubCommand) !void {
        return switch (self) {
            .Cook => |cmd| cmd.run(),
            .Pack => |cmd| cmd.run(),
            .Inspect => |cmd| cmd.run(),
        };
    }

    pub fn toString(self: SubCommand) []const u8 {
        return switch (self) {
            .Cook => "cook",
            .Pack => "pack",
            .Inspect => "inspect",
        };
    }

    pub fn deinit(self: SubCommand) void {
        return switch (self) {
            .Cook => |cmd| cmd.deinit(),
            .Pack => |cmd| cmd.deinit(),
            .Inspect => |cmd| cmd.deinit(),
        };
    }
};

pub const CookCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    io: std.Io,

    pub fn parseFromArgs(io: std.Io, args: []const [:0]const u8) ?CookCommand {
        const cwd = std.Io.Dir.cwd();
        var command: CookCommand = .{
            .source = cwd,
            .output = cwd,
        };

        if (args.len < 6) {
            std.log.err("Not enough arguments, must provide arguments '--source' and 'output' to 'cook' command", .{});
            return null;
        }

        var i: usize = 2;
        while (i < args.len) {
            if (std.mem.eql(u8, "--source", args[i])) {
                command.source = std.Io.Dir.openDir(cwd, io, args[i + 1], .{}) catch |err| {
                    std.log.err("Failed opening source dir: {s}, err: {}", .{ args[i + 1], err });
                    return null;
                };
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                command.output = std.Io.Dir.openDir(cwd, io, args[i + 1], .{}) catch |err| {
                    std.log.err("Failed opening output dir: {s}, err: {}", .{ args[i + 1], err });
                    return null;
                };
                i += 1;
            }

            i += 1;
        }

        return command;
    }

    pub fn run(_: CookCommand) !void {
        std.log.info("Running cook command", .{});
    }

    pub fn deinit(self: CookCommand) void {
        self.source.close(self.io);
        self.output.close(self.io);
    }
};

pub const PackCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    io: std.Io,

    pub fn parseFromArgs(io: std.Io, args: []const [:0]const u8) ?PackCommand {
        const cwd = std.Io.Dir.cwd();
        var command: PackCommand = .{
            .source = cwd,
            .output = cwd,
        };

        if (args.len < 6) {
            std.log.err("Not enough arguments, must provide arguments '--source' and 'output' to 'pack' command", .{});
            return null;
        }

        var i: usize = 2;
        while (i < args.len) {
            if (std.mem.eql(u8, "--source", args[i])) {
                command.source = std.Io.Dir.openDir(cwd, io, args[i + 1], .{}) catch |err| {
                    std.log.err("Failed opening source dir: {s}, err: {}", .{ args[i + 1], err });
                    return null;
                };
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                command.output = std.Io.Dir.openDir(cwd, io, args[i + 1], .{}) catch |err| {
                    std.log.err("Failed opening output dir: {s}, err: {}", .{ args[i + 1], err });
                    return null;
                };
                i += 1;
            }

            i += 1;
        }

        return command;
    }

    pub fn run(_: PackCommand) !void {
        std.log.info("Running pack command", .{});
    }

    pub fn deinit(self: PackCommand) void {
        self.source.close(self.io);
        self.output.close(self.io);
    }
};

pub const InspectCommand = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn parseFromArgs(io: std.Io, args: []const [:0]const u8) ?InspectCommand {
        const cwd = std.Io.Dir.cwd();

        if (args.len < 3) {
            std.log.err("Not enough arguments, must provide file for 'inspect' command", .{});
            return null;
        }

        const file = cwd.openFile(io, args[2], .{}) catch |err| {
            std.log.err("Error opening file: {}", .{err});
            return null;
        };

        return .{
            .file = file,
            .io = io,
        };
    }

    pub fn run(_: InspectCommand) !void {
        std.log.info("Running inspect command", .{});
    }

    pub fn deinit(self: InspectCommand) void {
        self.file.close(self.io);
    }
};

const testing = std.testing;

test "SubCommand.parse returns null for unknown command" {
    const args: []const [:0]const u8 = &.{ "zimp", "unknown" };
    const result = SubCommand.parse(testing.io, args);
    try testing.expect(result == null);
}

test "SubCommand.parse returns null for empty-like args" {
    const args: []const [:0]const u8 = &.{ "zimp", "" };
    const result = SubCommand.parse(testing.io, args);
    try testing.expect(result == null);
}

test "SubCommand.parse recognizes cook command" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const result = SubCommand.parse(testing.io, args);
    try testing.expect(result != null);
    try testing.expectEqualStrings("cook", result.?.toString());
    result.?.deinit();
}

test "SubCommand.parse recognizes pack command" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const result = SubCommand.parse(testing.io, args);
    try testing.expect(result != null);
    try testing.expectEqualStrings("pack", result.?.toString());
    result.?.deinit();
}

test "SubCommand.parse recognizes inspect command" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const result = SubCommand.parse(testing.io, args);
    try testing.expect(result != null);
    try testing.expectEqualStrings("inspect", result.?.toString());
    result.?.deinit();
}

test "SubCommand.toString returns correct strings" {
    const cook_args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cook = SubCommand.parse(testing.io, cook_args).?;
    defer cook.deinit();
    try testing.expectEqualStrings("cook", cook.toString());

    const pack_args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const pack = SubCommand.parse(testing.io, pack_args).?;
    defer pack.deinit();
    try testing.expectEqualStrings("pack", pack.toString());

    const inspect_args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const inspect = SubCommand.parse(testing.io, inspect_args).?;
    defer inspect.deinit();
    try testing.expectEqualStrings("inspect", inspect.toString());
}

test "SubCommand.run executes without error" {
    const cook_args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cook = SubCommand.parse(testing.io, cook_args).?;
    defer cook.deinit();
    try cook.run();

    const pack_args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const pack = SubCommand.parse(testing.io, pack_args).?;
    defer pack.deinit();
    try pack.run();

    const inspect_args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const inspect = SubCommand.parse(testing.io, inspect_args).?;
    defer inspect.deinit();
    try inspect.run();
}

test "CookCommand.parseFromArgs returns null with too few args" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook" };
    const result = CookCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "CookCommand.parseFromArgs returns null with partial args" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", "." };
    const result = CookCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "CookCommand.parseFromArgs succeeds with valid args" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const result = CookCommand.parseFromArgs(testing.io, args);
    try testing.expect(result != null);
    result.?.deinit();
}

test "CookCommand.parseFromArgs returns null for nonexistent source dir" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", "nonexistent_dir_abc123", "--output", "." };
    const result = CookCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "CookCommand.parseFromArgs returns null for nonexistent output dir" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "nonexistent_dir_abc123" };
    const result = CookCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "CookCommand.parseFromArgs accepts flags in any order" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--output", ".", "--source", "." };
    const result = CookCommand.parseFromArgs(testing.io, args);
    try testing.expect(result != null);
    result.?.deinit();
}

test "PackCommand.parseFromArgs returns null with too few args" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack" };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "PackCommand.parseFromArgs returns null with partial args" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "PackCommand.parseFromArgs succeeds with valid args" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expect(result != null);
    result.?.deinit();
}

test "PackCommand.parseFromArgs returns null for nonexistent source dir" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", "nonexistent_dir_abc123", "--output", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "PackCommand.parseFromArgs returns null for nonexistent output dir" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "nonexistent_dir_abc123" };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "PackCommand.parseFromArgs accepts flags in any order" {
    const args: []const [:0]const u8 = &.{ "zimp", "pack", "--output", ".", "--source", "." };
    const result = PackCommand.parseFromArgs(testing.io, args);
    try testing.expect(result != null);
    result.?.deinit();
}

test "InspectCommand.parseFromArgs returns null with too few args" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect" };
    const result = InspectCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "InspectCommand.parseFromArgs succeeds with valid file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const result = InspectCommand.parseFromArgs(testing.io, args);
    try testing.expect(result != null);
    result.?.deinit();
}

test "InspectCommand.parseFromArgs returns null for nonexistent file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "nonexistent_file_abc123.txt" };
    const result = InspectCommand.parseFromArgs(testing.io, args);
    try testing.expect(result == null);
}

test "SubCommand.deinit does not error" {
    const cook_args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cook = SubCommand.parse(testing.io, cook_args).?;
    cook.deinit();

    const pack_args: []const [:0]const u8 = &.{ "zimp", "pack", "--source", ".", "--output", "." };
    const pack = SubCommand.parse(testing.io, pack_args).?;
    pack.deinit();

    const inspect_args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const inspect = SubCommand.parse(testing.io, inspect_args).?;
    inspect.deinit();
}
