const std = @import("std");
const builtin = @import("builtin");

const cook_pipeline = @import("cook/pipeline.zig");
const CookContext = @import("cook/context.zig").CookContext;
const ProjectCookInfo = @import("cook/context.zig").ProjectCookInfo;
const ProjectRoot = @import("../project/project_root.zig").ProjectRoot;
const cook_metrics = @import("cook_metrics.zig");
const CountingAllocator = @import("../shared/counting_allocator.zig").CountingAllocator;
const log = @import("../logger.zig");

pub const CookError = error{
    NotEnoughArguments,
    SourceDirNotFound,
    OutputDirNotFound,
    MissingFlagValue,
    ConflictingFlags,
    ProjectOpenFailed,
    OutOfMemory,
    UnknownFlag,
    DuplicateFlag,
};

pub const CookCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    output_path: []const u8 = ".",
    io: std.Io,
    allocator: std.mem.Allocator,
    force: bool = false,
    emit_ci_metrics_json: bool = false,
    /// Set in `--project` mode; owns the manifest strings that
    /// `source`/`output`/`output_path` were derived from.
    project_root: ?*ProjectRoot = null,

    pub fn parseFromArgs(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) CookError!CookCommand {
        const cwd = std.Io.Dir.cwd();
        var command: CookCommand = .{
            .source = cwd,
            .output = cwd,
            .io = io,
            .allocator = allocator,
        };

        var source_arg: ?[]const u8 = null;
        var output_arg: ?[]const u8 = null;
        var project_arg: ?[]const u8 = null;

        var i: usize = 2;
        while (i < args.len) {
            if (std.mem.eql(u8, "--source", args[i])) {
                if (source_arg != null) return CookError.DuplicateFlag;
                if (i + 1 >= args.len) {
                    log.err("cook: missing value for --source", .{});
                    return CookError.MissingFlagValue;
                }
                source_arg = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, "--output", args[i])) {
                if (output_arg != null) return CookError.DuplicateFlag;
                if (i + 1 >= args.len) {
                    log.err("cook: missing value for --output", .{});
                    return CookError.MissingFlagValue;
                }
                output_arg = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, "--project", args[i])) {
                if (project_arg != null) return CookError.DuplicateFlag;
                if (i + 1 >= args.len) {
                    log.err("cook: missing value for --project", .{});
                    return CookError.MissingFlagValue;
                }
                project_arg = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, "--force", args[i])) {
                if (command.force) return CookError.DuplicateFlag;
                command.force = true;
            } else if (std.mem.eql(u8, "--metrics-json", args[i])) {
                if (command.emit_ci_metrics_json) return CookError.DuplicateFlag;
                command.emit_ci_metrics_json = true;
            } else {
                log.err("cook: unknown flag '{s}'", .{args[i]});
                return CookError.UnknownFlag;
            }

            i += 1;
        }

        if (project_arg) |project_path| {
            if (source_arg != null or output_arg != null) {
                log.err("cook: --project is mutually exclusive with --source/--output; the project manifest declares the directories", .{});
                return CookError.ConflictingFlags;
            }
            return parseProjectMode(&command, allocator, io, project_path);
        }

        if (source_arg == null or output_arg == null) {
            log.err("cook: both --source and --output are required. Usage: zimp cook --source <source_dir> --output <output_dir> (or zimp cook --project <root>)", .{});
            return CookError.NotEnoughArguments;
        }

        if (source_arg) |source_path| {
            command.source = std.Io.Dir.openDir(cwd, io, source_path, .{ .iterate = true }) catch |err| {
                log.err("cook: failed to open source directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ source_path, @errorName(err) });
                return CookError.SourceDirNotFound;
            };
        }
        if (output_arg) |output_path| {
            command.output = std.Io.Dir.openDir(cwd, io, output_path, .{ .iterate = true }) catch |err| {
                command.source.close(io);
                log.err("cook: failed to open output directory '{s}': {s}. Ensure the directory exists and has the correct permissions", .{ output_path, @errorName(err) });
                return CookError.OutputDirNotFound;
            };
            command.output_path = output_path;
        }

        return command;
    }

    fn parseProjectMode(command: *CookCommand, allocator: std.mem.Allocator, io: std.Io, project_path: []const u8) CookError!CookCommand {
        const pr = try allocator.create(ProjectRoot);
        errdefer allocator.destroy(pr);

        pr.* = ProjectRoot.open(allocator, io, project_path) catch |err| {
            log.err("cook: failed to open project '{s}': {s}. The directory must contain .zephyr/zephyr.proj", .{ project_path, @errorName(err) });
            return CookError.ProjectOpenFailed;
        };
        errdefer pr.deinit();

        command.project_root = pr;
        command.source = pr.openDir(pr.manifest.assets_dir, .{ .iterate = true }) catch |err| {
            log.err("cook: failed to open project assets dir '{s}': {s}", .{ pr.manifest.assets_dir, @errorName(err) });
            return CookError.SourceDirNotFound;
        };
        command.output = pr.makeOpenDir(pr.manifest.cooked_assets_dir) catch |err| {
            command.source.close(io);
            log.err("cook: failed to open project cooked dir '{s}': {s}", .{ pr.manifest.cooked_assets_dir, @errorName(err) });
            return CookError.OutputDirNotFound;
        };
        command.output_path = pr.resolve(pr.arena.allocator(), pr.manifest.cooked_assets_dir) catch {
            return CookError.OutOfMemory;
        };

        return command.*;
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
            .project = if (self.project_root) |pr| ProjectCookInfo{
                .project_id = pr.manifest.project_id,
                .root_dir = pr.root_dir,
                .manifest_path = pr.manifest.asset_manifest,
            } else null,
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
        if (metrics.assets_errored > 0) return error.AssetCookFailed;
    }

    pub fn deinit(self: *const CookCommand) void {
        self.source.close(self.io);
        self.output.close(self.io);
        if (self.project_root) |pr| {
            pr.deinit();
            self.allocator.destroy(pr);
        }
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

test "CookCommand.parseFromArgs rejects unknown flags even when argument count is sufficient" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--foo", "a", "--bar", "b" };
    try testing.expectError(CookError.UnknownFlag, CookCommand.parseFromArgs(testing.allocator, testing.io, args));
}

test "CookCommand.parseFromArgs rejects duplicate flags" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--source", ".", "--output", "." };
    try testing.expectError(CookError.DuplicateFlag, CookCommand.parseFromArgs(testing.allocator, testing.io, args));
}

test "CookCommand.run executes without error" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();
    const source_dir = try std.Io.Dir.openDir(source_tmp.dir, testing.io, ".", .{ .iterate = true });
    defer source_dir.close(testing.io);
    const output_dir = try std.Io.Dir.openDir(output_tmp.dir, testing.io, ".", .{ .iterate = true });
    defer output_dir.close(testing.io);

    const cmd: CookCommand = .{
        .source = source_dir,
        .output = output_dir,
        .io = testing.io,
        .allocator = testing.allocator,
    };
    try cmd.run(.none);

    const cache_file = try output_tmp.dir.openFile(testing.io, ".zcache", .{});
    cache_file.close(testing.io);
    try testing.expectError(error.FileNotFound, source_tmp.dir.openFile(testing.io, ".zcache", .{}));
}

test "CookCommand.run reports failures without leaving stale output" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();

    const source_file = try source_tmp.dir.createFile(testing.io, "bad.zamat", .{});
    var source_buf: [64]u8 = undefined;
    var source_writer = source_file.writer(testing.io, &source_buf);
    try source_writer.interface.writeAll("this is not valid material toml");
    try source_writer.interface.flush();
    source_file.close(testing.io);

    const stale_file = try output_tmp.dir.createFile(testing.io, "bad.zamat", .{});
    var stale_buf: [16]u8 = undefined;
    var stale_writer = stale_file.writer(testing.io, &stale_buf);
    try stale_writer.interface.writeAll("stale");
    try stale_writer.interface.flush();
    stale_file.close(testing.io);

    const source_dir = try std.Io.Dir.openDir(source_tmp.dir, testing.io, ".", .{ .iterate = true });
    defer source_dir.close(testing.io);
    const output_dir = try std.Io.Dir.openDir(output_tmp.dir, testing.io, ".", .{ .iterate = true });
    defer output_dir.close(testing.io);

    const cmd: CookCommand = .{
        .source = source_dir,
        .output = output_dir,
        .io = testing.io,
        .allocator = testing.allocator,
    };
    try testing.expectError(error.AssetCookFailed, cmd.run(.none));
    try testing.expectError(error.FileNotFound, output_tmp.dir.openFile(testing.io, "bad.zamat", .{}));

    const cache_file = try output_tmp.dir.openFile(testing.io, ".zcache", .{});
    cache_file.close(testing.io);
}

test "CookCommand.deinit cleans up without error" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--source", ".", "--output", "." };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    cmd.deinit();
}

test "CookCommand.parseFromArgs rejects --project combined with --source/--output" {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--project", ".", "--source", "." };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.ConflictingFlags, result);
}

test "CookCommand.parseFromArgs rejects --project without a manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(testing.io, ".", &real_path_buf);

    const root_z = try testing.allocator.dupeZ(u8, real_path_buf[0..len]);
    defer testing.allocator.free(root_z);
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--project", root_z };
    const result = CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    try testing.expectError(CookError.ProjectOpenFailed, result);
}

const manifest_codec = @import("../manifest/codec.zig");
const project_manifest_mod = @import("../project/manifest.zig");

fn runProjectCook(root_path: [:0]const u8) !void {
    const args: []const [:0]const u8 = &.{ "zimp", "cook", "--project", root_path };
    const cmd = try CookCommand.parseFromArgs(testing.allocator, testing.io, args);
    defer cmd.deinit();
    try cmd.run(.none);
}

test "project cook lifecycle: ids are minted once and survive everything but sidecar loss" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A minimal project: manifest + one authored shader source.
    const project: project_manifest_mod.ProjectManifest = .{
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    try project.save(testing.allocator, testing.io, tmp.dir);
    try tmp.dir.createDirPath(testing.io, ".zephyr/assets/shaders");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".zephyr/assets/shaders/tri.vert",
        .data = "#version 460 core\nvoid main() { gl_Position = vec4(0.0); }\n",
    });

    var real_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(testing.io, ".", &real_path_buf);
    const root_path = try testing.allocator.dupeZ(u8, real_path_buf[0..len]);
    defer testing.allocator.free(root_path);

    // First cook: mints an id, writes sidecar + manifest.
    try runProjectCook(root_path);

    const manifest_bytes_1 = try tmp.dir.readFileAlloc(testing.io, ".zephyr/assets.zmanifest", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(manifest_bytes_1);
    const sidecar_bytes_1 = try tmp.dir.readFileAlloc(testing.io, ".zephyr/assets/shaders/tri.vert.zmeta", testing.allocator, .limited(4096));
    defer testing.allocator.free(sidecar_bytes_1);

    var m1 = try manifest_codec.decode(testing.allocator, manifest_bytes_1);
    defer m1.deinit();
    try testing.expectEqual(@as(usize, 1), m1.entries.len);
    const original_id = m1.entries[0].id;
    try testing.expect(!original_id.isZero());

    // Recook: nothing changed, so the manifest is byte-identical and the
    // sidecar untouched.
    try runProjectCook(root_path);
    const manifest_bytes_2 = try tmp.dir.readFileAlloc(testing.io, ".zephyr/assets.zmanifest", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(manifest_bytes_2);
    const sidecar_bytes_2 = try tmp.dir.readFileAlloc(testing.io, ".zephyr/assets/shaders/tri.vert.zmeta", testing.allocator, .limited(4096));
    defer testing.allocator.free(sidecar_bytes_2);
    try testing.expectEqualStrings(manifest_bytes_1, manifest_bytes_2);
    try testing.expectEqualStrings(sidecar_bytes_1, sidecar_bytes_2);

    // Delete manifest + cooked output: identity survives via the sidecar.
    try tmp.dir.deleteFile(testing.io, ".zephyr/assets.zmanifest");
    try tmp.dir.deleteTree(testing.io, ".zephyr/cooked");
    try runProjectCook(root_path);
    const manifest_bytes_3 = try tmp.dir.readFileAlloc(testing.io, ".zephyr/assets.zmanifest", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(manifest_bytes_3);
    var m3 = try manifest_codec.decode(testing.allocator, manifest_bytes_3);
    defer m3.deinit();
    try testing.expect(m3.entries[0].id.eql(original_id));

    // A file copied together with its sidecar is a hard duplicate-id error.
    const src = try tmp.dir.readFileAlloc(testing.io, ".zephyr/assets/shaders/tri.vert", testing.allocator, .limited(4096));
    defer testing.allocator.free(src);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zephyr/assets/shaders/tri2.vert", .data = src });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zephyr/assets/shaders/tri2.vert.zmeta", .data = sidecar_bytes_1 });
    try testing.expectError(error.DuplicateAssetId, runProjectCook(root_path));
}
