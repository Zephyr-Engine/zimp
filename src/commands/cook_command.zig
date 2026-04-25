const std = @import("std");
const builtin = @import("builtin");

const cook_pipeline = @import("cook/pipeline.zig");
const CookContext = @import("cook/context.zig").CookContext;
const cook_metrics = @import("cook_metrics.zig");
const CountingAllocator = @import("../shared/counting_allocator.zig").CountingAllocator;
const log = @import("../logger.zig");

pub const CookError = error{
    NotEnoughArguments,
    SourceDirNotFound,
    OutputDirNotFound,
    MissingFlagValue,
};

pub const CookCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    output_path: []const u8 = ".",
    io: std.Io,
    allocator: std.mem.Allocator,
    force: bool = false,
    emit_ci_metrics_json: bool = false,

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
                if (i + 1 >= args.len) {
                    log.err("cook: missing value for --source", .{});
                    return CookError.MissingFlagValue;
                }
                command.source = std.Io.Dir.openDir(cwd, io, args[i + 1], .{ .iterate = true }) catch |err| {
                    log.err("cook: failed to open source directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ args[i + 1], @errorName(err) });
                    return CookError.SourceDirNotFound;
                };
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                if (i + 1 >= args.len) {
                    log.err("cook: missing value for --output", .{});
                    return CookError.MissingFlagValue;
                }
                command.output = std.Io.Dir.openDir(cwd, io, args[i + 1], .{ .iterate = true }) catch |err| {
                    log.err("cook: failed to open output directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ args[i + 1], @errorName(err) });
                    return CookError.OutputDirNotFound;
                };
                command.output_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, "--force", args[i])) {
                command.force = true;
            } else if (std.mem.eql(u8, "--metrics-json", args[i])) {
                command.emit_ci_metrics_json = true;
            }

            i += 1;
        }

        return command;
    }

    pub fn run(self: *const CookCommand, progress: std.Progress.Node) !void {
        const MetricsAllocator = std.heap.DebugAllocator(.{
            .enable_memory_limit = true,
            .thread_safe = false,
            .safety = false,
        });

        if (builtin.mode == .Debug) {
            var debug_allocator: MetricsAllocator = .{
                .backing_allocator = self.allocator,
            };
            defer _ = debug_allocator.deinit();

            var counting = CountingAllocator.init(debug_allocator.allocator());
            return self.runWithAllocator(counting.allocator(), &counting, progress);
        }

        // Release builds use the global SMP allocator for lower overhead and better throughput.
        var counting = CountingAllocator.init(std.heap.smp_allocator);
        return self.runWithAllocator(counting.allocator(), &counting, progress);
    }

    fn runWithAllocator(
        self: *const CookCommand,
        allocator: std.mem.Allocator,
        counting: *CountingAllocator,
        progress: std.Progress.Node,
    ) !void {
        const context: CookContext = .{
            .io = self.io,
            .source = self.source,
            .output = self.output,
            .output_path = self.output_path,
            .force = self.force,
        };

        const metrics = try cook_pipeline.run(allocator, counting, &context, progress);

        var total_duration_buf: [32]u8 = undefined;
        log.info("Cooked {d} assets in {s} ({d} cooked, {d} cached, {d} errored)", .{
            metrics.assets_total,
            fmtDuration(metrics.total_ns, &total_duration_buf),
            metrics.assets_cooked,
            metrics.assets_cached,
            metrics.assets_errored,
        });
        cook_metrics.logSummary(&metrics);
        if (self.emit_ci_metrics_json) {
            try cook_metrics.emitCiJson(allocator, &metrics);
        }
    }

    pub fn deinit(self: *const CookCommand) void {
        self.source.close(self.io);
        self.output.close(self.io);
    }
};

fn fmtDuration(nanoseconds: u64, buf: *[32]u8) []const u8 {
    if (nanoseconds >= std.time.ns_per_ms) {
        return std.fmt.bufPrint(buf, "{d}ms", .{nanoseconds / std.time.ns_per_ms}) catch unreachable;
    } else if (nanoseconds >= std.time.ns_per_us) {
        return std.fmt.bufPrint(buf, "{d}\xc2\xb5s", .{nanoseconds / std.time.ns_per_us}) catch unreachable;
    } else {
        return std.fmt.bufPrint(buf, "{d}ns", .{nanoseconds}) catch unreachable;
    }
}

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

test "CookCommand.parseFromArgs succeeds with force arg" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", ".", "--force" };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.force == true);
    try testing.expect(cmd.source.handle != 0);
    try testing.expect(cmd.output.handle != 0);
}

test "CookCommand.parseFromArgs accepts flags in any order" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--output", ".", "--source", "." };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();

    try testing.expect(cmd.force == false);
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
    try cmd.run(.none);
}

test "CookCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    cmd.deinit();
}
