const std = @import("std");

const zob = @import("zob");
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

pub const ProcessResult = enum { cached, hash_match, cooked, dependency_changed, skipped, errored };

const MetricsDelta = struct {
    source_bytes_read: u64 = 0,
    source_bytes_hashed: u64 = 0,
    cooked_bytes_written: u64 = 0,
};

const CacheUpdate = union(enum) {
    none,
    source_mtime: i96,
    cooked: struct {
        source_size: u64,
        cooked_size: u64,
    },
    dependency_only: u64,
    errored,
};

const CookJobResult = struct {
    entry: SourceFile,
    result: ProcessResult,
    cache_update: CacheUpdate = .none,
    metrics: MetricsDelta = .{},
};

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

const CookJob = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *const Cache,
    entry: SourceFile,
    force_recook: bool,
    cook_node: std.Progress.Node,

    pub fn execute(self: @This()) !CookJobResult {
        const asset_node = self.cook_node.start(self.entry.path, 0);
        defer asset_node.end();

        if (cookers.get(self.entry.extension) == null) {
            return self.processDependencyOnly();
        }

        const start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const decision = try self.decideAssetAction();

        return switch (decision.action) {
            .cached => .{
                .entry = self.entry,
                .result = .cached,
                .metrics = decision.metrics,
            },
            .hash_match => .{
                .entry = self.entry,
                .result = .hash_match,
                .cache_update = .{ .source_mtime = decision.source_mtime },
                .metrics = decision.metrics,
            },
            .cook => self.cookAndPrepareCache(decision.source_size, decision.metrics, start),
        };
    }

    const JobDecision = struct {
        action: AssetDecision.Action = .cook,
        source_size: u64 = 0,
        source_mtime: i96 = 0,
        metrics: MetricsDelta = .{},
    };

    fn processDependencyOnly(self: *const CookJob) !CookJobResult {
        var result = CookJobResult{
            .entry = self.entry,
            .result = .dependency_changed,
        };

        const info = try self.entry.getFileInfo(self.ctx.source, self.ctx.io);

        if (self.force_recook) {
            log.debug("{s} dependency changed, propagating to dependents", .{self.entry.path});
            result.cache_update = .{ .dependency_only = info.size };
            return result;
        }

        if (self.lookupEntry()) |cache_entry| {
            const staleness = try Staleness.check(self.ctx.io, self.ctx.source, cache_entry, &self.entry);
            if (staleness == .stale_content or staleness == .hash_match) {
                result.metrics.source_bytes_hashed += info.size;
            }

            switch (staleness) {
                .cached => {
                    log.debug("{s} is dependency-only and cached", .{self.entry.path});
                    result.result = .skipped;
                    return result;
                },
                .hash_match => {
                    log.debug("{s} dependency-only hash match, updated mtime", .{self.entry.path});
                    result.result = .skipped;
                    result.cache_update = .{ .source_mtime = info.modified_ns };
                    return result;
                },
                else => {
                    log.debug("{s} dependency-only source changed, propagating to dependents", .{self.entry.path});
                    result.cache_update = .{ .dependency_only = info.size };
                    return result;
                },
            }
        }

        log.debug("{s} dependency-only source first seen, propagating to dependents", .{self.entry.path});
        result.cache_update = .{ .dependency_only = info.size };
        return result;
    }

    fn decideAssetAction(self: *const CookJob) !JobDecision {
        var decision: JobDecision = .{};

        const info = try self.entry.getFileInfo(self.ctx.source, self.ctx.io);
        decision.source_size = info.size;
        decision.source_mtime = info.modified_ns;

        if (self.force_recook) {
            log.debug("{s} dependency changed, force recooking", .{self.entry.path});
            return decision;
        }

        if (self.lookupEntry()) |cache_entry| {
            const staleness = try Staleness.check(self.ctx.io, self.ctx.source, cache_entry, &self.entry);
            if (staleness == .stale_content or staleness == .hash_match) {
                decision.metrics.source_bytes_hashed += decision.source_size;
            }

            switch (staleness) {
                .cached => {
                    if (self.outputFileExists(cache_entry.cooked_path)) {
                        log.debug("{s} is cached, not cooking", .{self.entry.path});
                        decision.action = .cached;
                        return decision;
                    }
                    log.debug("{s} cached but output file missing, recooking", .{self.entry.path});
                },
                .hash_match => {
                    if (self.outputFileExists(cache_entry.cooked_path)) {
                        decision.action = .hash_match;
                        return decision;
                    }
                    log.debug("{s} hash match but output file missing, recooking", .{self.entry.path});
                },
                .errored => {
                    log.debug("{s} previously errored, retrying", .{self.entry.path});
                },
                else => {
                    log.debug("{s} is not cached, staleness: {s}", .{ self.entry.path, @tagName(staleness) });
                },
            }
        }

        return decision;
    }

    fn cookAndPrepareCache(
        self: *const CookJob,
        source_size: u64,
        initial_metrics: MetricsDelta,
        start: std.Io.Clock.Timestamp,
    ) !CookJobResult {
        var result = CookJobResult{
            .entry = self.entry,
            .result = .errored,
            .metrics = initial_metrics,
        };

        const cooker = cookers.get(self.entry.extension) orelse {
            log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ self.entry.extension.string(), self.entry.path });
            result.result = .skipped;
            return result;
        };

        const cooked_path = cooker.outputPath(self.allocator, self.entry.path) catch |err| {
            log.err("Failed to compute output path for '{s}': {s}", .{ self.entry.path, @errorName(err) });
            return result;
        };
        defer self.allocator.free(cooked_path);

        const cooked_file = self.ctx.output.createFile(self.ctx.io, cooked_path, .{}) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ self.entry.path, @errorName(err) });
            return result;
        };
        defer cooked_file.close(self.ctx.io);

        var buf: [8192]u8 = undefined;
        var file_writer = cooked_file.writer(self.ctx.io, &buf);

        const cook_failed = blk: {
            cooker.cook(self.allocator, self.ctx.io, self.ctx.source, self.entry.path, &file_writer.interface) catch |err| {
                log.err("Failed to cook '{s}': {s}", .{ self.entry.path, @errorName(err) });
                break :blk true;
            };
            break :blk false;
        };

        result.metrics.source_bytes_read += source_size;

        if (cook_failed) {
            result.cache_update = .errored;
            return result;
        }

        try file_writer.flush();

        const cooked_stat = try cooked_file.stat(self.ctx.io);

        const end = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const elapsed_ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        var duration_buf: [32]u8 = undefined;
        log.debug("Cooked '{s}' in {s}", .{ self.entry.path, fmtDuration(elapsed_ns, &duration_buf) });

        result.result = .cooked;
        result.metrics.cooked_bytes_written += cooked_stat.size;
        result.cache_update = .{
            .cooked = .{
                .source_size = source_size,
                .cooked_size = cooked_stat.size,
            },
        };
        return result;
    }

    fn lookupEntry(self: *const CookJob) ?*const CacheEntry {
        const idx = self.cache.getIdx(self.entry) orelse return null;
        return &self.cache.entries.items[idx];
    }

    fn outputFileExists(self: *const CookJob, cooked_path: []const u8) bool {
        if (cooked_path.len == 0) {
            return false;
        }

        const file = self.ctx.output.openFile(self.ctx.io, cooked_path, .{}) catch return false;
        file.close(self.ctx.io);

        return true;
    }
};

const LockedAllocator = struct {
    backing_allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    fn init(backing_allocator: std.mem.Allocator) LockedAllocator {
        return .{ .backing_allocator = backing_allocator };
    }

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn lock(self: *LockedAllocator) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
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

    pub fn run(self: *Executor, io: std.Io, progress: std.Progress.Node) !void {
        var scheduler = zob.Scheduler.init(io, self.allocator);
        var locked_allocator = LockedAllocator.init(self.allocator);
        const job_allocator = locked_allocator.allocator();

        var force_recook: std.AutoHashMap(Hash, void) = .init(self.allocator);
        defer force_recook.deinit();

        const cook_start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const cook_node = progress.start("Cooking assets", self.totalAssetCount());
        defer cook_node.end();

        for (self.levels) |level| {
            const jobs = try self.allocator.alloc(CookJob, level.len);
            defer self.allocator.free(jobs);

            for (level, jobs) |entry, *job| {
                job.* = .{
                    .allocator = job_allocator,
                    .ctx = self.ctx,
                    .cache = self.cache,
                    .entry = entry,
                    .force_recook = force_recook.contains(entry.hashPath()),
                    .cook_node = cook_node,
                };
            }

            var batch = try scheduler.submitBatch(CookJob, jobs, .normal);
            defer batch.deinit();

            const results = try batch.awaitAll(io);
            defer self.allocator.free(results);

            for (results) |result| {
                try self.applyJobResult(result, &force_recook);
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
            .dependency_changed => {},
            .errored => self.metrics.assets_errored += 1,
            .skipped => {},
        }
    }

    fn applyJobResult(self: *Executor, result: CookJobResult, force_recook: *std.AutoHashMap(Hash, void)) !void {
        self.metrics.source_bytes_read += result.metrics.source_bytes_read;
        self.metrics.source_bytes_hashed += result.metrics.source_bytes_hashed;
        self.metrics.cooked_bytes_written += result.metrics.cooked_bytes_written;

        self.recordResult(result.result);

        switch (result.cache_update) {
            .none => {},
            .source_mtime => |mtime| {
                if (self.cache.lookupEntryMut(result.entry)) |cache_entry| {
                    cache_entry.source_mtime = mtime;
                }
            },
            .cooked => |cooked| {
                try self.cacheCooked(result.entry, cooked.source_size, cooked.cooked_size);
            },
            .dependency_only => |source_size| {
                try self.cacheDependencyOnly(result.entry, source_size);
            },
            .errored => {
                try self.cacheErrored(result.entry, result.metrics.source_bytes_read);
            },
        }

        if (result.result == .cooked or result.result == .dependency_changed) {
            try self.enqueueDependents(result.entry.hashPath(), force_recook);
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

        if (cookers.get(entry.extension) == null) {
            return self.processDependencyOnly(entry, force_recook);
        }

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

    fn processDependencyOnly(self: *Executor, entry: SourceFile, force_recook: bool) !ProcessResult {
        const info = try entry.getFileInfo(self.ctx.source, self.ctx.io);

        if (force_recook) {
            try self.cacheDependencyOnly(entry, info.size);
            log.debug("{s} dependency changed, propagating to dependents", .{entry.path});
            return .dependency_changed;
        }

        if (self.cache.lookupEntryMut(entry)) |cache_entry| {
            const staleness = try Staleness.check(self.ctx.io, self.ctx.source, cache_entry, &entry);
            if (staleness == .stale_content or staleness == .hash_match) {
                self.metrics.source_bytes_hashed += info.size;
            }

            switch (staleness) {
                .cached => {
                    log.debug("{s} is dependency-only and cached", .{entry.path});
                    return .skipped;
                },
                .hash_match => {
                    cache_entry.source_mtime = info.modified_ns;
                    log.debug("{s} dependency-only hash match, updated mtime", .{entry.path});
                    return .skipped;
                },
                else => {
                    log.debug("{s} dependency-only source changed, propagating to dependents", .{entry.path});
                    try self.cacheDependencyOnly(entry, info.size);
                    return .dependency_changed;
                },
            }
        }

        try self.cacheDependencyOnly(entry, info.size);
        log.debug("{s} dependency-only source first seen, propagating to dependents", .{entry.path});
        return .dependency_changed;
    }

    fn cacheDependencyOnly(self: *Executor, entry: SourceFile, source_size: u64) !void {
        self.metrics.source_bytes_hashed += source_size;
        try self.cache.upsertEntry(
            self.allocator,
            entry,
            try CacheEntry.create(self.allocator, self.ctx.io, self.ctx.source, entry, "", 0),
        );
    }

    fn cacheCooked(self: *Executor, entry: SourceFile, source_size: u64, cooked_size: u64) !void {
        const cooker = cookers.get(entry.extension) orelse return;
        const cooked_path = try cooker.outputPath(self.allocator, entry.path);
        defer self.allocator.free(cooked_path);

        self.metrics.source_bytes_hashed += source_size;
        try self.cache.upsertEntry(
            self.allocator,
            entry,
            try CacheEntry.create(self.allocator, self.ctx.io, self.ctx.source, entry, cooked_path, cooked_size),
        );
    }

    fn cacheErrored(self: *Executor, entry: SourceFile, source_size: u64) !void {
        self.metrics.source_bytes_hashed += source_size;
        try self.cache.upsertEntry(
            self.allocator,
            entry,
            try CacheEntry.createErrored(self.allocator, self.ctx.io, self.ctx.source, entry),
        );
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

        const cooker = cookers.get(entry.extension) orelse {
            log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ entry.extension.string(), entry.path });
            return .skipped;
        };

        const cooked_path = cooker.outputPath(self.allocator, entry.path) catch |err| {
            log.err("Failed to compute output path for '{s}': {s}", .{ entry.path, @errorName(err) });
            return .errored;
        };
        defer self.allocator.free(cooked_path);

        const cooked_file = self.ctx.output.createFile(self.ctx.io, cooked_path, .{}) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ entry.path, @errorName(err) });
            return .errored;
        };
        defer cooked_file.close(self.ctx.io);

        var buf: [8192]u8 = undefined;
        var file_writer = cooked_file.writer(self.ctx.io, &buf);

        const cook_failed = blk: {
            cooker.cook(self.allocator, self.ctx.io, self.ctx.source, entry.path, &file_writer.interface) catch |err| {
                log.err("Failed to cook '{s}': {s}", .{ entry.path, @errorName(err) });
                break :blk true;
            };
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

        const cooked_stat = try cooked_file.stat(self.ctx.io);

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
            try CacheEntry.create(self.allocator, self.ctx.io, self.ctx.source, entry, cooked_path, cooked_stat.size),
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
