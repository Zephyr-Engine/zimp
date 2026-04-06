const std = @import("std");

const AssetScanner = @import("../asset_scanner.zig").AssetScanner;
const GLBCooker = @import("../gltf/cook.zig").GLBCooker;
const log = @import("../logger.zig");

pub const CookError = error{
    NotEnoughArguments,
    SourceDirNotFound,
    OutputDirNotFound,
};

pub const CookCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn parseFromArgs(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) CookError!CookCommand {
        const cwd = std.Io.Dir.cwd();
        var command: CookCommand = .{
            .source = cwd,
            .output = cwd,
            .io = io,
            .allocator = allocator,
        };

        if (args.len < 6) {
            log.err("cook: not enough arguments (got {d}, need at least 6). Usage: zimp cook --source <source_dir> --output <output_dir>", .{args.len});
            return CookError.NotEnoughArguments;
        }

        var i: usize = 2;
        while (i < args.len) {
            if (std.mem.eql(u8, "--source", args[i])) {
                command.source = std.Io.Dir.openDir(cwd, io, args[i + 1], .{ .iterate = true }) catch |err| {
                    log.err("cook: failed to open source directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ args[i + 1], @errorName(err) });
                    return CookError.SourceDirNotFound;
                };
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                command.output = std.Io.Dir.openDir(cwd, io, args[i + 1], .{ .iterate = true }) catch |err| {
                    log.err("cook: failed to open output directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ args[i + 1], @errorName(err) });
                    return CookError.OutputDirNotFound;
                };
                i += 1;
            }

            i += 1;
        }

        return command;
    }

    pub fn run(self: CookCommand) !void {
        log.info("Running cook command", .{});

        const source_scanner = AssetScanner.init(self.allocator, self.io, self.source);
        var list = try source_scanner.scan();

        defer source_scanner.deinit(&list);

        // TODO: parallelize this with zob
        for (list.items) |entry| {
            const start = std.Io.Clock.Timestamp.now(self.io, .awake);

            const file = entry.createCookedFile(self.allocator, self.io, self.output) catch |err| {
                log.err("Failed to create output file for '{s}': {s}", .{ entry.path, @errorName(err) });
                return err;
            };
            defer file.close(self.io);

            var buf: [8192]u8 = undefined;
            var file_writer = file.writer(self.io, &buf);

            if (entry.extension == .glb) {
                var glb_cooker = try GLBCooker.init(self.allocator, self.io, self.source, entry.path);
                defer glb_cooker.deinit();
                try glb_cooker.cook(self.allocator, &file_writer.interface);
            }

            try file_writer.flush();

            const end = std.Io.Clock.Timestamp.now(self.io, .awake);
            const elapsed_ns = start.durationTo(end).raw.nanoseconds;
            const elapsed_ms: i64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
            log.info("Cooked '{s}' in {d}ms", .{ entry.path, elapsed_ms });
        }
    }

    pub fn deinit(self: CookCommand) void {
        self.source.close(self.io);
        self.output.close(self.io);
    }
};

const testing = std.testing;

test "CookCommand.parseFromArgs errors with NotEnoughArguments when no flags provided" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook" };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.NotEnoughArguments, result);
}

test "CookCommand.parseFromArgs errors with NotEnoughArguments with only --source" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", "." };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.NotEnoughArguments, result);
}

test "CookCommand.parseFromArgs errors with NotEnoughArguments with only --output" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--output", "." };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.NotEnoughArguments, result);
}

test "CookCommand.parseFromArgs errors with SourceDirNotFound for nonexistent source" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", "nonexistent_dir_abc123", "--output", "." };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.SourceDirNotFound, result);
}

test "CookCommand.parseFromArgs errors with OutputDirNotFound for nonexistent output" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "nonexistent_dir_abc123" };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.OutputDirNotFound, result);
}

test "CookCommand.parseFromArgs succeeds with valid args" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.source.handle != 0);
    try testing.expect(cmd.output.handle != 0);
}

test "CookCommand.parseFromArgs accepts flags in any order" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--output", ".", "--source", "." };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.source.handle != 0);
    try testing.expect(cmd.output.handle != 0);
}

test "CookCommand.run executes without error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cmd: CookCommand = .{
        .source = std.Io.Dir.openDir(std.Io.Dir.cwd(), testing.io, "examples/assets", .{ .iterate = true }) catch unreachable,
        .output = tmp.dir,
        .io = testing.io,
        .allocator = testing.allocator,
    };
    try cmd.run();
}

test "CookCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    cmd.deinit();
}
