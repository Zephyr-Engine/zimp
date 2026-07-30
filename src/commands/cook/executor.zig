const std = @import("std");

const zob = @import("zob");
const asset_registry = @import("../../assets/asset_registry.zig");
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
const SourceIndex = @import("planner.zig").SourceIndex;
const SourceRecord = @import("planner.zig").SourceRecord;
const AtomicFile = @import("../../shared/atomic_file.zig").AtomicFile;
const AssetType = @import("../../assets/asset.zig").AssetType;
const zmesh = @import("../../formats/zmesh.zig");
const ztex = @import("../../formats/ztex.zig");
const zshdr = @import("../../formats/zshdr.zig");
const zamat = @import("../../formats/zamat.zig");
const HashedSource = @import("source_analysis.zig").HashedSource;
const CookInput = @import("../../cookers/cooker.zig").CookInput;

pub const ProcessResult = enum { cached, hash_match, cooked, dependency_changed, skipped, errored };

const MetricsDelta = struct {
    source_bytes_read: u64 = 0,
    source_bytes_hashed: u64 = 0,
    cooked_bytes_written: u64 = 0,
};

const CacheUpdate = union(enum) {
    none,
    source_mtime: i96,
    cooked: u64,
    dependency_only,
    errored,
};

const CookJobResult = struct {
    entry: SourceFile,
    result: ProcessResult,
    cache_update: CacheUpdate = .none,
    metrics: MetricsDelta = .{},
    source_info: ?SourceFile.FileInfo = null,
    content_hash: ?Hash = null,
    output_path: ?[]const u8 = null,
};

const CookJob = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *const Cache,
    record: *const SourceRecord,
    force_recook: bool,
    cook_node: std.Progress.Node,

    pub fn execute(self: @This()) !CookJobResult {
        var runner = CookJobRunner{
            .allocator = self.allocator,
            .ctx = self.ctx,
            .cache = self.cache,
            .record = self.record,
            .descriptor = self.record.descriptor,
            .force_recook = self.force_recook,
            .cook_node = self.cook_node,
        };
        return runner.execute();
    }
};

const CookJobRunner = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *const Cache,
    record: *const SourceRecord,
    descriptor: asset_registry.AssetDescriptor,
    force_recook: bool,
    cook_node: std.Progress.Node,

    pub fn execute(self: *const CookJobRunner) !CookJobResult {
        const asset_node = self.cook_node.start(self.record.source.path, 0);
        defer asset_node.end();

        var analyzed = HashedSource.init(self.allocator, self.record.source, self.record.info);
        defer analyzed.deinit();

        if (self.descriptor.cooker == null) {
            return self.processDependencyOnly(&analyzed);
        }

        const start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const decision = try self.decideAssetAction(&analyzed);

        return switch (decision.action) {
            .cached => .{
                .entry = self.record.source,
                .result = .cached,
                .metrics = decision.metrics,
            },
            .hash_match => .{
                .entry = self.record.source,
                .result = .hash_match,
                .cache_update = .{ .source_mtime = decision.source_mtime },
                .metrics = decision.metrics,
            },
            .cook => self.cookAndPrepareCache(&analyzed, decision.metrics, start),
        };
    }

    const JobDecision = struct {
        action: Action = .cook,
        source_mtime: i96 = 0,
        metrics: MetricsDelta = .{},

        const Action = enum {
            cached,
            hash_match,
            cook,
        };
    };

    fn processDependencyOnly(self: *const CookJobRunner, analyzed: *HashedSource) !CookJobResult {
        var result = CookJobResult{
            .entry = self.record.source,
            .result = .dependency_changed,
        };

        const info = self.record.info;

        if (self.force_recook) {
            log.debug("{s} dependency changed, propagating to dependents", .{self.record.source.path});
            try self.attachSnapshot(&result, analyzed);
            result.cache_update = .dependency_only;
            return result;
        }

        if (self.lookupEntry()) |cache_entry| {
            const source_hash = if (cache_entry.source_mtime != info.modified_ns and cache_entry.source_size == info.size) try analyzed.hash(self.ctx.io, self.ctx.source) else null;
            const staleness = Staleness.check(cache_entry, info, source_hash, self.cache.host_os);
            self.recordAnalysisMetrics(&result.metrics, analyzed);

            switch (staleness.verdict) {
                .cached => {
                    log.debug("{s} is dependency-only and cached", .{self.record.source.path});
                    result.result = .skipped;
                    return result;
                },
                .hash_match => {
                    log.debug("{s} dependency-only hash match, updated mtime", .{self.record.source.path});
                    result.result = .skipped;
                    result.cache_update = .{ .source_mtime = info.modified_ns };
                    return result;
                },
                else => {
                    log.debug("{s} dependency-only source changed, propagating to dependents", .{self.record.source.path});
                    try self.attachSnapshot(&result, analyzed);
                    result.cache_update = .dependency_only;
                    return result;
                },
            }
        }

        log.debug("{s} dependency-only source first seen, propagating to dependents", .{self.record.source.path});
        try self.attachSnapshot(&result, analyzed);
        result.cache_update = .dependency_only;
        return result;
    }

    fn decideAssetAction(self: *const CookJobRunner, analyzed: *HashedSource) !JobDecision {
        var decision: JobDecision = .{};

        const info = self.record.info;
        decision.source_mtime = info.modified_ns;

        if (self.force_recook) {
            log.debug("{s} dependency changed, force recooking", .{self.record.source.path});
            return decision;
        }

        if (self.lookupEntry()) |cache_entry| {
            const source_hash = if (cache_entry.source_mtime != info.modified_ns and cache_entry.source_size == info.size)
                try analyzed.hash(self.ctx.io, self.ctx.source)
            else
                null;
            const staleness = Staleness.check(cache_entry, info, source_hash, self.cache.host_os);
            self.recordAnalysisMetrics(&decision.metrics, analyzed);

            switch (staleness.verdict) {
                .cached => {
                    if (self.outputFileIsCurrent(cache_entry.cooked_path)) {
                        log.debug("{s} is cached, not cooking", .{self.record.source.path});
                        decision.action = .cached;
                        return decision;
                    }
                    log.debug("{s} cached output is missing or uses an outdated format, recooking", .{self.record.source.path});
                },
                .hash_match => {
                    if (self.outputFileIsCurrent(cache_entry.cooked_path)) {
                        decision.action = .hash_match;
                        return decision;
                    }
                    log.debug("{s} hash match but output is missing or uses an outdated format, recooking", .{self.record.source.path});
                },
                .errored => {
                    log.debug("{s} previously errored, retrying", .{self.record.source.path});
                },
                else => {
                    log.debug("{s} is not cached, staleness: {s}", .{ self.record.source.path, @tagName(staleness.verdict) });
                },
            }
        }

        return decision;
    }

    fn cookAndPrepareCache(
        self: *const CookJobRunner,
        analyzed: *HashedSource,
        initial_metrics: MetricsDelta,
        start: std.Io.Clock.Timestamp,
    ) !CookJobResult {
        var result = CookJobResult{
            .entry = self.record.source,
            .result = .errored,
            .metrics = initial_metrics,
        };

        const cooker = self.descriptor.cooker orelse {
            log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ self.record.source.extension.string(), self.record.source.path });
            result.result = .skipped;
            return result;
        };

        const cooked_path = self.record.output_path orelse return result;

        if (std.fs.path.dirname(cooked_path)) |parent| {
            self.ctx.output.createDirPath(self.ctx.io, parent) catch |err| {
                log.err("Failed to create output directory for '{s}': {s}", .{ self.record.source.path, @errorName(err) });
                return result;
            };
        }

        var pending_file = AtomicFile.create(self.allocator, self.ctx.io, self.ctx.output, cooked_path) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ self.record.source.path, @errorName(err) });
            return result;
        };
        defer pending_file.deinit();

        var buf: [8192]u8 = undefined;
        var file_writer = pending_file.file.writer(self.ctx.io, &buf);

        const source_bytes = try analyzed.data(self.ctx.io, self.ctx.source);
        try self.attachSnapshot(&result, analyzed);
        result.output_path = cooked_path;
        const input = CookInput{
            .allocator = self.allocator,
            .io = self.ctx.io,
            .source_dir = self.ctx.source,
            .source = self.record.source,
            .bytes = source_bytes,
            .writer = &file_writer.interface,
        };

        const cook_failed = blk: {
            cooker.cook(&input) catch |err| {
                log.err("Failed to cook '{s}': {s}", .{ self.record.source.path, @errorName(err) });
                break :blk true;
            };
            break :blk false;
        };

        if (cook_failed) {
            self.ctx.output.deleteFile(self.ctx.io, cooked_path) catch |err| {
                if (err != error.FileNotFound)
                    log.warn("Failed to remove stale output '{s}': {s}", .{ cooked_path, @errorName(err) });
            };
            result.cache_update = .errored;
            return result;
        }

        try file_writer.flush();

        const cooked_stat = try pending_file.file.stat(self.ctx.io);
        try pending_file.commit();

        const end = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const elapsed_ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        var duration_buf: [32]u8 = undefined;
        log.debug("Cooked '{s}' in {s}", .{ self.record.source.path, fmtDuration(elapsed_ns, &duration_buf) });

        result.result = .cooked;
        result.metrics.cooked_bytes_written += cooked_stat.size;
        result.cache_update = .{ .cooked = cooked_stat.size };
        return result;
    }

    fn lookupEntry(self: *const CookJobRunner) ?*const CacheEntry {
        const idx = self.record.cached_index orelse return null;
        return &self.cache.entries.items[idx];
    }

    fn outputFileIsCurrent(self: *const CookJobRunner, cooked_path: []const u8) bool {
        return cookedFileIsCurrent(self.ctx.io, self.ctx.output, cooked_path, self.descriptor.asset_type);
    }

    fn attachSnapshot(self: *const CookJobRunner, result: *CookJobResult, analyzed: *HashedSource) !void {
        result.source_info = self.record.info;
        result.content_hash = try analyzed.hash(self.ctx.io, self.ctx.source);
        self.recordAnalysisMetrics(&result.metrics, analyzed);
    }

    fn recordAnalysisMetrics(_: *const CookJobRunner, metrics: *MetricsDelta, analyzed: *const HashedSource) void {
        metrics.source_bytes_read = analyzed.bytes_read;
        metrics.source_bytes_hashed = analyzed.bytes_read;
    }
};

const CookedHeader = struct {
    magic: []const u8,
    version: u32,
};

fn currentCookedHeader(asset_type: AssetType) ?CookedHeader {
    return switch (asset_type) {
        .mesh => .{ .magic = zmesh.MAGIC, .version = zmesh.ZMESH_VERSION },
        .texture => .{ .magic = ztex.MAGIC, .version = ztex.ZATEX_VERSION },
        .shader => .{ .magic = zshdr.MAGIC, .version = zshdr.ZSHDR_VERSION },
        .material => .{ .magic = zamat.MAGIC, .version = zamat.ZAMAT_VERSION },
        .unknown => null,
    };
}

fn cookedFileIsCurrent(io: std.Io, output: std.Io.Dir, cooked_path: []const u8, asset_type: AssetType) bool {
    if (cooked_path.len == 0) return false;

    const file = output.openFile(io, cooked_path, .{}) catch return false;
    defer file.close(io);

    var buf: [16]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    var magic: [5]u8 = undefined;
    file_reader.interface.readSliceAll(&magic) catch return false;
    const version = file_reader.interface.takeInt(u32, .little) catch return false;
    const expected = currentCookedHeader(asset_type) orelse return false;
    return std.mem.eql(u8, &magic, expected.magic) and version == expected.version;
}

const MetricsAccumulator = struct {
    metrics: *CookMetrics,
    counting: *CountingAllocator,

    fn recordJobResult(self: *MetricsAccumulator, result: CookJobResult) void {
        self.metrics.source_bytes_read += result.metrics.source_bytes_read;
        self.metrics.source_bytes_hashed += result.metrics.source_bytes_hashed;
        self.metrics.cooked_bytes_written += result.metrics.cooked_bytes_written;

        switch (result.result) {
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

    fn markPeak(self: *MetricsAccumulator) void {
        cook_metrics.markPeak(self.metrics, self.counting.peakRequestedBytes());
    }
};

const CookCacheUpdater = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,

    fn apply(self: *CookCacheUpdater, result: CookJobResult) !void {
        switch (result.cache_update) {
            .none => {},
            .source_mtime => |mtime| {
                if (self.cache.lookupEntryMut(result.entry)) |cache_entry| {
                    cache_entry.source_mtime = mtime;
                }
            },
            .cooked => |cooked_size| try self.cacheCooked(result, cooked_size),
            .dependency_only => try self.cacheDependencyOnly(result),
            .errored => {
                try self.cacheErrored(result);
            },
        }
    }

    fn cacheDependencyOnly(self: *CookCacheUpdater, result: CookJobResult) !void {
        const info = result.source_info orelse return error.MissingSourceSnapshot;
        const content_hash = result.content_hash orelse return error.MissingSourceSnapshot;
        try self.cache.upsertEntry(
            self.allocator,
            result.entry,
            try CacheEntry.init(self.allocator, self.io, result.entry, info, content_hash, "", 0),
        );
    }

    fn cacheCooked(self: *CookCacheUpdater, result: CookJobResult, cooked_size: u64) !void {
        const info = result.source_info orelse return error.MissingSourceSnapshot;
        const content_hash = result.content_hash orelse return error.MissingSourceSnapshot;
        const output_path = result.output_path orelse return error.MissingOutputPath;
        try self.cache.upsertEntry(
            self.allocator,
            result.entry,
            try CacheEntry.init(self.allocator, self.io, result.entry, info, content_hash, output_path, cooked_size),
        );
    }

    fn cacheErrored(self: *CookCacheUpdater, result: CookJobResult) !void {
        const info = result.source_info orelse return error.MissingSourceSnapshot;
        const content_hash = result.content_hash orelse return error.MissingSourceSnapshot;
        try self.cache.upsertEntry(
            self.allocator,
            result.entry,
            try CacheEntry.initErrored(self.allocator, result.entry, info, content_hash),
        );
    }
};

const InvalidationTracker = struct {
    reverse: *const DependentsMap,
    forced: std.AutoHashMap(Hash, void),

    fn init(allocator: std.mem.Allocator, reverse: *const DependentsMap) InvalidationTracker {
        return .{
            .reverse = reverse,
            .forced = .init(allocator),
        };
    }

    fn deinit(self: *InvalidationTracker) void {
        self.forced.deinit();
    }

    fn isForced(self: *const InvalidationTracker, entry: SourceFile) bool {
        return self.forced.contains(entry.hashPath());
    }

    fn enqueueIfChanged(self: *InvalidationTracker, result: CookJobResult) !void {
        if (result.result == .cooked or result.result == .dependency_changed) {
            try self.enqueueDependents(result.entry.hashPath());
        }
    }

    fn enqueueDependents(self: *InvalidationTracker, hash: Hash) !void {
        if (self.reverse.get(hash)) |dependents| {
            for (dependents.items) |dep_hash| {
                try self.forced.put(dep_hash, {});
            }
        }
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    metrics: *CookMetrics,
    cache: *Cache,
    records: []const SourceRecord,
    levels: [][]SourceIndex,
    reverse: *const DependentsMap,
    counting: *CountingAllocator,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *const CookContext,
        metrics: *CookMetrics,
        cache: *Cache,
        records: []const SourceRecord,
        levels: [][]SourceIndex,
        reverse: *const DependentsMap,
        counting: *CountingAllocator,
    ) Executor {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .metrics = metrics,
            .cache = cache,
            .records = records,
            .levels = levels,
            .reverse = reverse,
            .counting = counting,
        };
    }

    pub fn run(self: *Executor, io: std.Io, progress: std.Progress.Node) !void {
        var scheduler = zob.Scheduler.init(io, self.allocator);
        const job_allocator = self.allocator;

        var invalidation = InvalidationTracker.init(self.allocator, self.reverse);
        defer invalidation.deinit();
        var cache_updater = CookCacheUpdater{
            .allocator = self.allocator,
            .io = self.ctx.io,
            .cache = self.cache,
        };
        var metrics_accumulator = MetricsAccumulator{
            .metrics = self.metrics,
            .counting = self.counting,
        };

        const cook_start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const cook_node = progress.start("Cooking assets", self.totalAssetCount());
        defer cook_node.end();

        for (self.levels) |level| {
            const jobs = try self.allocator.alloc(CookJob, level.len);
            defer self.allocator.free(jobs);

            for (level, jobs) |source_index, *job| {
                const record = &self.records[source_index];
                job.* = .{
                    .allocator = job_allocator,
                    .ctx = self.ctx,
                    .cache = self.cache,
                    .record = record,
                    .force_recook = invalidation.isForced(record.source),
                    .cook_node = cook_node,
                };
            }

            var batch = try scheduler.submitBatch(CookJob, jobs, .normal);
            defer batch.deinit();

            const results = try batch.awaitAll(io);
            defer self.allocator.free(results);

            for (results) |result| {
                metrics_accumulator.recordJobResult(result);
                try cache_updater.apply(result);
                try invalidation.enqueueIfChanged(result);
                metrics_accumulator.markPeak();
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

test "cooked file version mismatch invalidates only that cached output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "mesh.zmesh", .{});
    var buf: [32]u8 = undefined;
    var writer = file.writer(std.testing.io, &buf);
    try writer.interface.writeAll(zmesh.MAGIC);
    try writer.interface.writeInt(u32, zmesh.ZMESH_VERSION - 1, .little);
    try writer.interface.flush();
    file.close(std.testing.io);

    try std.testing.expect(!cookedFileIsCurrent(std.testing.io, tmp.dir, "mesh.zmesh", .mesh));

    const current = try tmp.dir.createFile(std.testing.io, "mesh.zmesh", .{ .truncate = true });
    var current_buf: [32]u8 = undefined;
    var current_writer = current.writer(std.testing.io, &current_buf);
    try current_writer.interface.writeAll(zmesh.MAGIC);
    try current_writer.interface.writeInt(u32, zmesh.ZMESH_VERSION, .little);
    try current_writer.interface.flush();
    current.close(std.testing.io);

    try std.testing.expect(cookedFileIsCurrent(std.testing.io, tmp.dir, "mesh.zmesh", .mesh));
}
