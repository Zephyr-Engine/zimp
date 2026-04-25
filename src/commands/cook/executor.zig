const std = @import("std");

const cookers = @import("../../cookers/cooker.zig").cooker_registry;
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const Hash = @import("../../assets/source_file.zig").Hash;
const Staleness = @import("../../cache/staleness.zig").Staleness;
const CacheEntry = @import("../../cache/entry.zig").CacheEntry;
const Cache = @import("../../cache/cache.zig").Cache;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const cook_metrics = @import("../cook_metrics.zig");
const CountingAllocator = @import("../../shared/counting_allocator.zig").CountingAllocator;
const log = @import("../../logger.zig");
const CookContext = @import("context.zig").CookContext;
const DependentsMap = @import("planner.zig").DependentsMap;

pub const ProcessResult = enum { cached, hash_match, cooked, skipped, errored };

const AssetDecision = struct {
    action: Action = .cook,
    source_size: u64 = 0,
    cache_entry: ?*CacheEntry = null,

    const Action = enum {
        cached,
        hash_match,
        cook,
    };
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    metrics: *CookMetrics,
    cache: *Cache,
    levels: [][]SourceFile,
    reverse: *const DependentsMap,
    counting: *CountingAllocator,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *const CookContext,
        metrics: *CookMetrics,
        cache: *Cache,
        levels: [][]SourceFile,
        reverse: *const DependentsMap,
        counting: *CountingAllocator,
    ) Executor {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .metrics = metrics,
            .cache = cache,
            .levels = levels,
            .reverse = reverse,
            .counting = counting,
        };
    }

    pub fn run(self: *Executor, progress: std.Progress.Node) !void {
        var force_recook: std.AutoHashMap(Hash, void) = .init(self.allocator);
        defer force_recook.deinit();

        const cook_start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const cook_node = progress.start("Cooking assets", self.totalAssetCount());
        defer cook_node.end();

        // TODO: parallelize entries within each level with zob; levels themselves must run sequentially
        for (self.levels) |level| {
            for (level) |entry| {
                const force = force_recook.contains(entry.hashPath());
                const result = try self.processAsset(entry, cook_node, force);

                self.recordResult(result);

                if (result == .cooked) {
                    try self.enqueueDependents(entry.hashPath(), &force_recook);
                }

                cook_metrics.markPeak(self.metrics, self.counting.peak_requested_bytes);
            }
        }

        const cook_end = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        self.metrics.cook_ns = @intCast(cook_start.durationTo(cook_end).raw.nanoseconds);
    }

    fn totalAssetCount(self: *const Executor) usize {
        var total: usize = 0;
        for (self.levels) |level| {
            total += level.len;
        }
        return total;
    }

    fn recordResult(self: *Executor, result: ProcessResult) void {
        switch (result) {
            .cached => self.metrics.assets_cached += 1,
            .hash_match => {
                self.metrics.assets_cached += 1;
                self.metrics.assets_hash_match += 1;
            },
            .cooked => self.metrics.assets_cooked += 1,
            .errored => self.metrics.assets_errored += 1,
            .skipped => {},
        }
    }

    fn enqueueDependents(self: *Executor, hash: Hash, queue: *std.AutoHashMap(Hash, void)) !void {
        if (self.reverse.get(hash)) |dependents| {
            for (dependents.items) |dep_hash| {
                try queue.put(dep_hash, {});
            }
        }
    }

    fn processAsset(self: *Executor, entry: SourceFile, cook_node: std.Progress.Node, force_recook: bool) !ProcessResult {
        const asset_node = cook_node.start(entry.path, 0);
        defer asset_node.end();

        const start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const decision = try self.decideAssetAction(entry, force_recook);

        return switch (decision.action) {
            .cached => .cached,
            .hash_match => blk: {
                const cache_entry = decision.cache_entry orelse unreachable;
                const updated_info = try entry.getFileInfo(self.ctx.source, self.ctx.io);
                cache_entry.source_mtime = updated_info.modified_ns;
                log.debug("{s} hash match, updated mtime", .{entry.path});
                break :blk .hash_match;
            },
            .cook => self.cookAndCache(entry, decision.source_size, start),
        };
    }

    fn decideAssetAction(self: *Executor, entry: SourceFile, force_recook: bool) !AssetDecision {
        var decision: AssetDecision = .{};

        if (force_recook) {
            log.debug("{s} dependency changed, force recooking", .{entry.path});
            return decision;
        }

        if (self.cache.lookupEntryMut(entry)) |cache_entry| {
            const info = try entry.getFileInfo(self.ctx.source, self.ctx.io);
            decision.source_size = info.size;

            const staleness = try Staleness.check(self.ctx.io, self.ctx.source, cache_entry, &entry);
            if (staleness == .stale_content or staleness == .hash_match) {
                self.metrics.source_bytes_hashed += decision.source_size;
            }

            switch (staleness) {
                .cached => {
                    if (self.outputFileExists(cache_entry.cooked_path)) {
                        log.debug("{s} is cached, not cooking", .{entry.path});
                        decision.action = .cached;
                        return decision;
                    }
                    log.debug("{s} cached but output file missing, recooking", .{entry.path});
                },
                .hash_match => {
                    if (self.outputFileExists(cache_entry.cooked_path)) {
                        decision.action = .hash_match;
                        decision.cache_entry = cache_entry;
                        return decision;
                    }
                    log.debug("{s} hash match but output file missing, recooking", .{entry.path});
                },
                .errored => {
                    log.debug("{s} previously errored, retrying", .{entry.path});
                },
                else => {
                    log.debug("{s} is not cached, staleness: {s}", .{ entry.path, @tagName(staleness) });
                },
            }
        }

        return decision;
    }

    fn cookAndCache(self: *Executor, entry: SourceFile, initial_source_size: u64, start: std.Io.Clock.Timestamp) !ProcessResult {
        var source_size = initial_source_size;
        if (source_size == 0) {
            const info = try entry.getFileInfo(self.ctx.source, self.ctx.io);
            source_size = info.size;
        }

        const cooked = entry.createCookedFile(self.allocator, self.ctx.io, self.ctx.output) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ entry.path, @errorName(err) });
            return .errored;
        };
        defer self.allocator.free(cooked.path);
        defer cooked.file.close(self.ctx.io);

        var buf: [8192]u8 = undefined;
        var file_writer = cooked.file.writer(self.ctx.io, &buf);

        const cook_failed = blk: {
            if (cookers.get(entry.extension)) |cooker| {
                cooker.cook(self.allocator, self.ctx.io, self.ctx.source, entry.path, &file_writer.interface) catch |err| {
                    log.err("Failed to cook '{s}': {s}", .{ entry.path, @errorName(err) });
                    break :blk true;
                };
            } else {
                log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ entry.extension.string(), entry.path });
            }
            break :blk false;
        };

        if (cook_failed) {
            const errored_entry = CacheEntry.createErrored(self.allocator, self.ctx.io, self.ctx.source, entry) catch |err| {
                log.err("Failed to create errored cache entry for '{s}': {s}", .{ entry.path, @errorName(err) });
                return .errored;
            };

            // Cooker attempted a read, and errored cache entry computes a content hash.
            self.metrics.source_bytes_read += source_size;
            self.metrics.source_bytes_hashed += source_size;
            try self.cache.upsertEntry(self.allocator, entry, errored_entry);
            return .errored;
        }

        try file_writer.flush();

        const cooked_stat = try cooked.file.stat(self.ctx.io);

        const end = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const elapsed_ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        var duration_buf: [32]u8 = undefined;
        log.debug("Cooked '{s}' in {s}", .{ entry.path, fmtDuration(elapsed_ns, &duration_buf) });

        // Cooker reads source once; cache entry creation hashes source once.
        self.metrics.source_bytes_read += source_size;
        self.metrics.source_bytes_hashed += source_size;
        self.metrics.cooked_bytes_written += cooked_stat.size;

        try self.cache.upsertEntry(
            self.allocator,
            entry,
            try CacheEntry.create(self.allocator, self.ctx.io, self.ctx.source, entry, cooked.path, cooked_stat.size),
        );

        return .cooked;
    }

    fn outputFileExists(self: *const Executor, cooked_path: []const u8) bool {
        if (cooked_path.len == 0) {
            return false;
        }

        const file = self.ctx.output.openFile(self.ctx.io, cooked_path, .{}) catch return false;
        file.close(self.ctx.io);

        return true;
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
