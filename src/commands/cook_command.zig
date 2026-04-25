const std = @import("std");
const builtin = @import("builtin");

const cookers = @import("../cookers/cooker.zig").cooker_registry;
const extractDependencies = @import("../extractors/extractor.zig").extractDependencies;
const AssetScanner = @import("../assets/asset_scanner.zig").AssetScanner;
const source_file_mod = @import("../assets/source_file.zig");
const SourceFile = source_file_mod.SourceFile;
const Hash = source_file_mod.Hash;
const DepGraph = @import("../assets/dependency_graph.zig").DepGraph;
const Staleness = @import("../cache/staleness.zig").Staleness;
const CacheEntry = @import("../cache/entry.zig").CacheEntry;
const Cache = @import("../cache/cache.zig").Cache;
const cook_metrics = @import("cook_metrics.zig");
const CookMetrics = cook_metrics.CookMetrics;
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
        const FastAllocator = std.mem.Allocator;
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
        const fast_allocator: FastAllocator = std.heap.smp_allocator;
        var counting = CountingAllocator.init(fast_allocator);
        return self.runWithAllocator(counting.allocator(), &counting, progress);
    }

    fn runWithAllocator(
        self: *const CookCommand,
        allocator: std.mem.Allocator,
        counting: *CountingAllocator,
        progress: std.Progress.Node,
    ) !void {
        var metrics: CookMetrics = .{};
        const total_start = std.Io.Clock.Timestamp.now(self.io, .awake);

        var cache = blk: {
            if (self.force) {
                break :blk try Cache.init(allocator, self.source, self.output_path);
            }

            break :blk Cache.readFromDir(allocator, self.io, self.source, self.output_path) catch |err| {
                switch (err) {
                    error.OutputDirChanged => log.debug("Output directory changed, rebuilding cache", .{}),
                    error.StaleVersion => log.debug("Outdated cache version found, rebuilding entire cache", .{}),
                    error.UnsupportedVersion => log.debug("Corrupt cache found, rebuilding entire cache", .{}),
                    error.FileNotFound => log.debug("No existing cache found, starting fresh", .{}),
                    else => log.debug("Failed to read cache ({s}), starting fresh", .{@errorName(err)}),
                }
                break :blk try Cache.init(allocator, self.source, self.output_path);
            };
        };
        defer cache.deinit(allocator);
        cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

        const scan_start = std.Io.Clock.Timestamp.now(self.io, .awake);
        const source_scanner = AssetScanner.init(allocator, self.io, self.source);
        var list = try source_scanner.scan();
        defer source_scanner.deinit(&list);
        const scan_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        metrics.scan_ns = @intCast(scan_start.durationTo(scan_end).raw.nanoseconds);
        metrics.assets_total = @intCast(list.items.len);
        cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

        const pruned = cache.pruneDeleted(allocator, list.items);
        if (pruned > 0) {
            log.debug("Removed {d} deleted source file(s) from cache", .{pruned});
        }

        const dep_start = std.Io.Clock.Timestamp.now(self.io, .awake);
        var dep_graph = DepGraph.init(allocator);
        defer dep_graph.deinit();
        try self.buildDependencyGraph(allocator, &dep_graph, list.items);
        const dep_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        metrics.dependency_graph_ns = @intCast(dep_start.durationTo(dep_end).raw.nanoseconds);
        log.debug("Built dependency graph: {d} edge(s) across {d} source file(s)", .{
            dep_graph.totalDependencyCount(),
            list.items.len,
        });
        cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

        const cook_levels = try dep_graph.cookLevels(list.items);
        defer DepGraph.freeLevels(allocator, cook_levels);

        var reverse = try dep_graph.buildReverse(allocator);
        defer {
            var rev_iter = reverse.iterator();
            while (rev_iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            reverse.deinit();
        }

        var force_recook: std.AutoHashMap(Hash, void) = .init(allocator);
        defer force_recook.deinit();

        const cook_start = std.Io.Clock.Timestamp.now(self.io, .awake);
        const cook_node = progress.start("Cooking assets", list.items.len);
        defer cook_node.end();

        // TODO: parallelize entries within each level with zob; levels themselves must run sequentially
        for (cook_levels) |level| {
            for (level) |entry| {
                const force = force_recook.contains(entry.hashPath());
                const result = try self.processAsset(allocator, &metrics, &cache, entry, cook_node, force);

                switch (result) {
                    .cached => metrics.assets_cached += 1,
                    .hash_match => {
                        metrics.assets_cached += 1;
                        metrics.assets_hash_match += 1;
                    },
                    .cooked => metrics.assets_cooked += 1,
                    .errored => metrics.assets_errored += 1,
                    .skipped => {},
                }

                if (result == .cooked) {
                    if (reverse.get(entry.hashPath())) |dependents| {
                        for (dependents.items) |dep_hash| {
                            try force_recook.put(dep_hash, {});
                        }
                    }
                }
                cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);
            }
        }
        const cook_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        metrics.cook_ns = @intCast(cook_start.durationTo(cook_end).raw.nanoseconds);

        const cache_write_start = std.Io.Clock.Timestamp.now(self.io, .awake);
        try cache.write(self.io);
        const cache_write_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        metrics.cache_write_ns = @intCast(cache_write_start.durationTo(cache_write_end).raw.nanoseconds);

        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(self.io, ".zcache", .{})) |cache_file| {
            defer cache_file.close(self.io);
            const cache_stat = cache_file.stat(self.io) catch null;
            if (cache_stat) |st| {
                metrics.cache_bytes_written = st.size;
            }
        } else |_| {}

        const total_end = std.Io.Clock.Timestamp.now(self.io, .awake);
        metrics.total_ns = @intCast(total_start.durationTo(total_end).raw.nanoseconds);
        metrics.ending_allocated_bytes = counting.current_requested_bytes;
        cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

        var total_duration_buf: [32]u8 = undefined;
        log.info("Cooked {d} assets in {s} ({d} cooked, {d} cached, {d} errored)", .{
            list.items.len,
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

    fn buildDependencyGraph(
        self: *const CookCommand,
        allocator: std.mem.Allocator,
        dep_graph: *DepGraph,
        source_files: []const SourceFile,
    ) !void {
        for (source_files) |source| {
            const deps = extractDependencies(&source, self.source, self.io, allocator) catch |err| {
                log.warn("Failed to extract dependencies for '{s}': {s}", .{ source.path, @errorName(err) });
                continue;
            };
            defer {
                for (deps) |d| allocator.free(d.path);
                allocator.free(deps);
            }

            const from = source.hashPath();
            for (deps) |dep| {
                try dep_graph.addDependency(from, dep.hashPath());
            }
        }
    }

    const ProcessResult = enum { cached, hash_match, cooked, skipped, errored };

    fn processAsset(
        self: *const CookCommand,
        allocator: std.mem.Allocator,
        metrics: *CookMetrics,
        cache: *Cache,
        entry: SourceFile,
        cook_node: std.Progress.Node,
        force_recook: bool,
    ) !ProcessResult {
        const asset_node = cook_node.start(entry.path, 0);
        defer asset_node.end();

        const start = std.Io.Clock.Timestamp.now(self.io, .awake);
        var source_size: u64 = 0;

        if (force_recook) {
            log.debug("{s} dependency changed, force recooking", .{entry.path});
        } else if (cache.lookupEntryMut(entry)) |cache_entry| {
            const info = try entry.getFileInfo(self.source, self.io);
            source_size = info.size;

            const staleness = try Staleness.check(self.io, self.source, cache_entry, &entry);
            if (staleness == .stale_content or staleness == .hash_match) {
                metrics.source_bytes_hashed += source_size;
            }

            if (staleness == .cached) {
                if (self.outputFileExists(cache_entry.cooked_path)) {
                    log.debug("{s} is cached, not cooking", .{entry.path});
                    return .cached;
                }
                log.debug("{s} cached but output file missing, recooking", .{entry.path});
            }

            if (staleness == .hash_match) {
                if (self.outputFileExists(cache_entry.cooked_path)) {
                    const updated_info = try entry.getFileInfo(self.source, self.io);
                    cache_entry.source_mtime = updated_info.modified_ns;
                    log.debug("{s} hash match, updated mtime", .{entry.path});
                    return .hash_match;
                }
                log.debug("{s} hash match but output file missing, recooking", .{entry.path});
            }

            if (staleness == .errored) {
                log.debug("{s} previously errored, retrying", .{entry.path});
            } else {
                log.debug("{s} is not cached, staleness: {s}", .{ entry.path, @tagName(staleness) });
            }
        }

        if (source_size == 0) {
            const info = try entry.getFileInfo(self.source, self.io);
            source_size = info.size;
        }

        const cooked = entry.createCookedFile(allocator, self.io, self.output) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ entry.path, @errorName(err) });
            return .errored;
        };
        defer allocator.free(cooked.path);
        defer cooked.file.close(self.io);

        var buf: [8192]u8 = undefined;
        var file_writer = cooked.file.writer(self.io, &buf);

        const cook_failed = blk: {
            if (cookers.get(entry.extension)) |cooker| {
                cooker.cook(allocator, self.io, self.source, entry.path, &file_writer.interface) catch |err| {
                    log.err("Failed to cook '{s}': {s}", .{ entry.path, @errorName(err) });
                    break :blk true;
                };
            } else {
                log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ entry.extension.string(), entry.path });
            }
            break :blk false;
        };

        if (cook_failed) {
            const errored_entry = CacheEntry.createErrored(allocator, self.io, self.source, entry) catch |err| {
                log.err("Failed to create errored cache entry for '{s}': {s}", .{ entry.path, @errorName(err) });
                return .errored;
            };

            // Cooker attempted a read, and errored cache entry computes a content hash.
            metrics.source_bytes_read += source_size;
            metrics.source_bytes_hashed += source_size;
            try cache.upsertEntry(allocator, entry, errored_entry);
            return .errored;
        }

        try file_writer.flush();

        const cooked_stat = try cooked.file.stat(self.io);

        const end = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed_ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        var duration_buf: [32]u8 = undefined;
        log.debug("Cooked '{s}' in {s}", .{ entry.path, fmtDuration(elapsed_ns, &duration_buf) });

        // Cooker reads source once; cache entry creation hashes source once.
        metrics.source_bytes_read += source_size;
        metrics.source_bytes_hashed += source_size;
        metrics.cooked_bytes_written += cooked_stat.size;

        try cache.upsertEntry(
            allocator,
            entry,
            try CacheEntry.create(allocator, self.io, self.source, entry, cooked.path, cooked_stat.size),
        );

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
