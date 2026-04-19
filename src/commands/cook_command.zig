const std = @import("std");

const cookers = @import("../cookers/cooker.zig").cooker_registry;
const AssetScanner = @import("../assets/asset_scanner.zig").AssetScanner;
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const Staleness = @import("../cache/staleness.zig").Staleness;
const CacheEntry = @import("../cache/entry.zig").CacheEntry;
const Cache = @import("../cache/cache.zig").Cache;
const log = @import("../logger.zig");

pub const CookError = error{
    NotEnoughArguments,
    SourceDirNotFound,
    OutputDirNotFound,
};

pub const CookCommand = struct {
    source: std.Io.Dir,
    output: std.Io.Dir,
    output_path: []const u8 = ".",
    io: std.Io,
    allocator: std.mem.Allocator,
    force: bool = false,

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
                command.output_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, "--force", args[i])) {
                command.force = true;
            }

            i += 1;
        }

        return command;
    }

    pub fn run(self: *const CookCommand, progress: std.Progress.Node) !void {
        var cache = blk: {
            if (self.force) {
                break :blk try Cache.init(self.allocator, self.source, self.output_path);
            }

            break :blk Cache.readFromDir(self.allocator, self.io, self.source, self.output_path) catch |err| {
                switch (err) {
                    error.OutputDirChanged => log.debug("Output directory changed, rebuilding cache", .{}),
                    error.StaleVersion => log.debug("Outdated cache version found, rebuilding entire cache", .{}),
                    error.UnsupportedVersion => log.debug("Corrupt cache found, rebuilding entire cache", .{}),
                    error.FileNotFound => log.debug("No existing cache found, starting fresh", .{}),
                    else => log.debug("Failed to read cache ({s}), starting fresh", .{@errorName(err)}),
                }
                break :blk try Cache.init(self.allocator, self.source, self.output_path);
            };
        };
        defer cache.deinit(self.allocator);

        const source_scanner = AssetScanner.init(self.allocator, self.io, self.source);
        var list = try source_scanner.scan();

        defer source_scanner.deinit(&list);

        const pruned = cache.pruneDeleted(self.allocator, list.items);
        if (pruned > 0) {
            log.debug("Removed {d} deleted source file(s) from cache", .{pruned});
        }

        const total_start = std.Io.Clock.Timestamp.now(self.io, .awake);

        const cook_node = progress.start("Cooking assets", list.items.len);
        defer cook_node.end();

        var cache_count: u32 = 0;

        // TODO: parallelize this with zob
        for (list.items) |entry| {
            const result = try self.processAsset(&cache, entry, cook_node);
            if (result == .cached or result == .hash_match) {
                cache_count += 1;
            }
        }

        const total_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        const total_elapsed_ns: u64 = @intCast(total_start.durationTo(total_end).raw.nanoseconds);
        var total_duration_buf: [32]u8 = undefined;
        log.info("Cooked {d} assets in {s}({d} cached)", .{
            list.items.len,
            fmtDuration(total_elapsed_ns, &total_duration_buf),
            cache_count,
        });

        try cache.write(self.io);
    }

    const ProcessResult = enum { cached, hash_match, cooked, skipped, errored };

    fn processAsset(self: *const CookCommand, cache: *Cache, entry: SourceFile, cook_node: std.Progress.Node) !ProcessResult {
        const asset_node = cook_node.start(entry.path, 0);

        const start = std.Io.Clock.Timestamp.now(self.io, .awake);
        var staleness: ?Staleness = null;
        if (cache.lookupEntryMut(entry)) |cache_entry| {
            staleness = try Staleness.check(self.io, self.source, cache_entry, &entry);
            if (staleness == .cached) {
                if (self.outputFileExists(cache_entry.cooked_path)) {
                    log.debug("{s} is cached, not cooking", .{entry.path});
                    return .cached;
                }
                log.debug("{s} cached but output file missing, recooking", .{entry.path});
            }

            if (staleness == .hash_match) {
                if (self.outputFileExists(cache_entry.cooked_path)) {
                    const info = try entry.getFileInfo(self.source, self.io);
                    cache_entry.source_mtime = info.modified_ns;
                    log.debug("{s} hash match, updated mtime", .{entry.path});
                    return .hash_match;
                }
                log.debug("{s} hash match but output file missing, recooking", .{entry.path});
            }

            if (staleness == .errored) {
                log.debug("{s} previously errored, retrying", .{entry.path});
            } else {
                log.debug("{s} is not cached, staleness: {s}", .{ entry.path, @tagName(staleness.?) });
            }
        }

        const cooked = entry.createCookedFile(self.allocator, self.io, self.output) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ entry.path, @errorName(err) });
            return .errored;
        };
        defer self.allocator.free(cooked.path);
        defer cooked.file.close(self.io);

        var buf: [8192]u8 = undefined;
        var file_writer = cooked.file.writer(self.io, &buf);

        const cook_failed = blk: {
            if (cookers.get(entry.extension)) |cooker| {
                cooker.cook(self.allocator, self.io, self.source, entry.path, &file_writer.interface) catch |err| {
                    log.err("Failed to cook '{s}': {s}", .{ entry.path, @errorName(err) });
                    break :blk true;
                };
            } else {
                log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ entry.extension.string(), entry.path });
            }
            break :blk false;
        };

        if (cook_failed) {
            const errored_entry = CacheEntry.createErrored(self.allocator, self.io, self.source, entry) catch |err| {
                log.err("Failed to create errored cache entry for '{s}': {s}", .{ entry.path, @errorName(err) });
                return .errored;
            };

            try cache.upsertEntry(self.allocator, entry, errored_entry);
            return .errored;
        }

        try file_writer.flush();

        const cooked_stat = try cooked.file.stat(self.io);

        const end = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed_ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        var duration_buf: [32]u8 = undefined;
        log.debug("Cooked '{s}' in {s}", .{ entry.path, fmtDuration(elapsed_ns, &duration_buf) });

        try cache.upsertEntry(
            self.allocator,
            entry,
            try CacheEntry.create(self.allocator, self.io, self.source, entry, cooked.path, cooked_stat.size),
        );

        asset_node.end();
        return .cooked;
    }

    fn outputFileExists(self: *const CookCommand, cooked_path: []const u8) bool {
        if (cooked_path.len == 0) {
            return false;
        }

        const file = self.output.openFile(self.io, cooked_path, .{}) catch return false;
        file.close(self.io);

        return true;
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
