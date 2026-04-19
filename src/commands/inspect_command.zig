const std = @import("std");

const log = @import("../logger.zig");
const inspectors = @import("../inspectors/inspect.zig").inspector_registry;

pub const InspectError = error{
    NotEnoughArguments,
    FileNotFound,
    UnkownFormat,
};

pub const InspectCommand = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn parseFromArgs(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) InspectError!InspectCommand {
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
            .allocator = allocator,
            .file = file,
            .io = io,
        };
    }

    pub fn run(self: InspectCommand) !void {
        log.info("Running inspect command", .{});

        var buf: [8192]u8 = undefined;
        var file_reader = self.file.reader(self.io, &buf);
        var reader = &file_reader.interface;

        var magic: [5]u8 = undefined;
        try reader.readSliceAll(&magic);

        const inspector = inspectors.get(&magic) orelse {
            log.err("No inspector found for file with magic '{s}'", .{magic});
            return InspectError.UnkownFormat;
        };

        try inspector.inspect(self.allocator, reader);
    }

    pub fn deinit(self: InspectCommand) void {
        self.file.close(self.io);
    }
};

const testing = std.testing;
const writeTestZmeshFile = @import("../formats/zmesh.zig").writeTestZmeshFile;

test "InspectCommand.parseFromArgs errors with NotEnoughArguments when no file provided" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect" };
    const result = InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.NotEnoughArguments, result);
}

test "InspectCommand.parseFromArgs errors with FileNotFound for nonexistent file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "nonexistent_file_abc123.txt" };
    const result = InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.FileNotFound, result);
}

test "InspectCommand.parseFromArgs succeeds with valid file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.file.handle != 0);
}

test "InspectCommand.parseFromArgs stores allocator" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expectEqual(testing.allocator, cmd.allocator);
}

test "InspectCommand.run returns UnkownFormat for non-asset file" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();
    try testing.expectError(InspectError.UnkownFormat, cmd.run());
}

test "InspectCommand.run succeeds for valid zmesh file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a minimal zmesh file
    const file = try tmp.dir.createFile(testing.io, "test.zmesh", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writeTestZmeshFile(&writer.interface);
    try writer.flush();
    file.close(testing.io);

    // Inspect it
    const inspect_file = try tmp.dir.openFile(testing.io, "test.zmesh", .{});
    const cmd: InspectCommand = .{
        .allocator = testing.allocator,
        .file = inspect_file,
        .io = testing.io,
    };
    defer cmd.deinit();
    try cmd.run();
}

test "InspectCommand.parseFromArgs errors with NotEnoughArguments for single arg" {
    const args: []const [:0]const u8 = &.{"zimp"};
    const result = InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(InspectError.NotEnoughArguments, result);
}

test "InspectCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "inspect", "build.zig" };
    const cmd = try InspectCommand.parseFromArgs(testing.allocator, testing.io, args);
    cmd.deinit();
}
