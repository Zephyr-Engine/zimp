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
            .Cook => return,
            .Pack => return,
            .Inspect => |cmd| cmd.deinit(),
        };
    }
};

pub const CookCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,

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
};

pub const PackCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,

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
