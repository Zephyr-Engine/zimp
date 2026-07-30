const std = @import("std");

const asset_registry = @import("../../assets/asset_registry.zig");
const AssetScanner = @import("../../assets/asset_scanner.zig").AssetScanner;
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const Hash = @import("../../assets/source_file.zig").Hash;
const DepGraph = @import("../../assets/dependency_graph.zig").DepGraph;
const Cache = @import("../../cache/cache.zig").Cache;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const log = @import("../../logger.zig");
const CookContext = @import("context.zig").CookContext;
const material_generator = @import("../../parsers/gltf/material_generator.zig");

const Dependencies = std.ArrayList(Hash);
pub const DependentsMap = std.AutoHashMap(Hash, Dependencies);
pub const SourceIndex = u32;

/// Stable, dense source state.  Paths are sorted before records are assigned so
/// indexes are deterministic across identical scans.
pub const SourceRecord = struct {
    source: SourceFile,
    info: SourceFile.FileInfo,
    descriptor: asset_registry.AssetDescriptor,
    output_path: ?[]const u8,
    cached_index: ?u32,
};

pub const CookPlan = struct {
    records: std.ArrayList(SourceRecord),
    levels: [][]SourceIndex,
    reverse: DependentsMap,

    pub fn deinit(self: *CookPlan, allocator: std.mem.Allocator) void {
        for (self.records.items) |record| {
            allocator.free(record.source.path);
            if (record.output_path) |path| allocator.free(path);
        }
        self.records.deinit(allocator);

        freeLevels(allocator, self.levels);

        var reverse_iter = self.reverse.iterator();
        while (reverse_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.reverse.deinit();
    }
};

pub fn build(allocator: std.mem.Allocator, ctx: *const CookContext, cache: *Cache, metrics: *CookMetrics) !CookPlan {
    const scan_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const scanner = AssetScanner.init(allocator, ctx.io, ctx.source);
    var scanned = try scanner.scan();
    errdefer {
        for (scanned.items) |file| {
            allocator.free(file.path);
        }
        scanned.deinit(allocator);
    }

    var generation_sources: std.ArrayList(SourceFile) = .empty;
    defer generation_sources.deinit(allocator);
    for (scanned.items) |source| {
        if (try needsMaterialGeneration(source, ctx, cache)) {
            try generation_sources.append(allocator, source);
        }
    }

    const generated_materials = try material_generator.generateForSources(allocator, ctx.io, ctx.source, generation_sources.items);
    if (generated_materials > 0) {
        log.debug("Generated {d} material source file(s), rescanning assets", .{generated_materials});
        scanner.deinit(&scanned);
        scanned = try scanner.scan();
    }
    const scan_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    metrics.scan_ns = @intCast(scan_start.durationTo(scan_end).raw.nanoseconds);
    std.mem.sort(SourceFile, scanned.items, {}, struct {
        fn lessThan(_: void, a: SourceFile, b: SourceFile) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var records: std.ArrayList(SourceRecord) = .empty;
    errdefer {
        for (records.items) |record| {
            allocator.free(record.source.path);
            if (record.output_path) |path| allocator.free(path);
        }
        records.deinit(allocator);
    }
    try records.ensureTotalCapacity(allocator, scanned.items.len);
    for (scanned.items) |source| {
        const descriptor = asset_registry.descriptorForSource(source);
        const info = try source.getFileInfo(ctx.source, ctx.io);
        const output_path = if (descriptor.cooker) |cooker|
            try cooker.outputPath(allocator, source.path)
        else
            null;
        records.appendAssumeCapacity(.{
            .source = source,
            .info = info,
            .descriptor = descriptor,
            .output_path = output_path,
            .cached_index = cache.getIdx(source),
        });
    }
    // Ownership of paths moved into records.
    scanned.deinit(allocator);
    scanned = .empty;

    metrics.assets_total = @intCast(records.items.len);

    try validateUniqueOutputs(allocator, records.items);

    const dep_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    var dep_graph = DepGraph.init(allocator);
    defer dep_graph.deinit();

    try buildDependencyGraph(allocator, ctx, cache, &dep_graph, records.items);

    const dep_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.dependency_graph_ns = @intCast(dep_start.durationTo(dep_end).raw.nanoseconds);

    log.debug("Built dependency graph: {d} edge(s) across {d} source file(s)", .{
        dep_graph.totalDependencyCount(),
        records.items.len,
    });

    const source_files = try sourceSlice(allocator, records.items);
    defer allocator.free(source_files);
    const source_levels = try dep_graph.cookLevels(source_files);
    defer DepGraph.freeLevels(allocator, source_levels);
    const levels = try indexLevels(allocator, records.items, source_levels);
    errdefer freeLevels(allocator, levels);

    var reverse = try dep_graph.buildReverse(allocator);
    errdefer deinitReverse(allocator, &reverse);

    return .{
        .records = records,
        .levels = levels,
        .reverse = reverse,
    };
}

fn needsMaterialGeneration(source: SourceFile, ctx: *const CookContext, cache: *const Cache) !bool {
    if (source.extension != .glb and source.extension != .gltf) {
        return false;
    }

    const cache_index = cache.getIdx(source) orelse return true;
    const entry = cache.entries.items[cache_index];
    if (entry.isErrored()) {
        return true;
    }

    const info = try source.getFileInfo(ctx.source, ctx.io);
    if (entry.source_size != info.size) {
        return true;
    }
    if (entry.source_mtime == info.modified_ns) {
        return false;
    }

    return entry.content_hash != try source.hash(ctx.source, ctx.io);
}

pub fn sourceSlice(allocator: std.mem.Allocator, records: []const SourceRecord) ![]SourceFile {
    const files = try allocator.alloc(SourceFile, records.len);
    for (records, files) |record, *file| {
        file.* = record.source;
    }
    return files;
}

fn indexLevels(allocator: std.mem.Allocator, records: []const SourceRecord, source_levels: []const []const SourceFile) ![][]SourceIndex {
    var indexes = std.AutoHashMap(Hash, SourceIndex).init(allocator);
    defer indexes.deinit();
    try indexes.ensureTotalCapacity(@intCast(records.len));
    for (records, 0..) |record, index| {
        indexes.putAssumeCapacity(record.source.hashPath(), @intCast(index));
    }

    const levels = try allocator.alloc([]SourceIndex, source_levels.len);
    errdefer allocator.free(levels);
    var built: usize = 0;
    errdefer {
        for (levels[0..built]) |level| allocator.free(level);
    }
    for (source_levels, 0..) |source_level, level_index| {
        const level = try allocator.alloc(SourceIndex, source_level.len);
        levels[level_index] = level;
        built += 1;
        for (source_level, level) |source, *index| {
            index.* = indexes.get(source.hashPath()) orelse return error.MissingSourceRecord;
        }
    }
    return levels;
}

fn freeLevels(allocator: std.mem.Allocator, levels: [][]SourceIndex) void {
    for (levels) |level| allocator.free(level);
    allocator.free(levels);
}

fn validateUniqueOutputs(allocator: std.mem.Allocator, records: []const SourceRecord) !void {
    var outputs = std.StringHashMap([]const u8).init(allocator);
    defer outputs.deinit();

    for (records) |record| {
        const output_path = record.output_path orelse continue;

        const gop = try outputs.getOrPut(output_path);
        if (gop.found_existing) {
            log.err("Cooked output collision: '{s}' and '{s}' both map to '{s}'", .{
                gop.value_ptr.*,
                record.source.path,
                output_path,
            });
            return error.DuplicateCookedOutput;
        }
        gop.key_ptr.* = output_path;
        gop.value_ptr.* = record.source.path;
    }
}

fn buildDependencyGraph(
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *Cache,
    dep_graph: *DepGraph,
    records: []const SourceRecord,
) !void {
    for (records) |record| {
        const source = record.source;

        if (cache.lookupDependencyRow(source)) |row| {
            if (row.isFresh(record.info)) {
                const from = source.hashPath();
                for (row.dependencies.items) |dep| {
                    try dep_graph.addDependency(from, dep.path_hash);
                }
                continue;
            }
        }

        const deps = asset_registry.extractDependencies(&source, ctx.source, ctx.io, allocator) catch |err| {
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

        try cache.upsertDependencyRow(allocator, source, record.info, deps);
    }
}

fn deinitReverse(allocator: std.mem.Allocator, reverse: *DependentsMap) void {
    var iter = reverse.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    reverse.deinit();
}

const testing = std.testing;

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

test "buildDependencyGraph reuses fresh cached dependency rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "main.frag", "void main() {}\n");

    const source = SourceFile.fromPath("main.frag");
    const dep = SourceFile.fromPath("common.glsl");
    const info = try source.getFileInfo(tmp.dir, testing.io);

    var cache = try Cache.init(testing.allocator, tmp.dir, ".");
    defer cache.deinit(testing.allocator);
    try cache.upsertDependencyRow(testing.allocator, source, info, &.{dep});

    const ctx = CookContext{
        .io = testing.io,
        .source = tmp.dir,
        .output = tmp.dir,
        .output_path = ".",
        .force = false,
    };

    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try buildDependencyGraph(testing.allocator, &ctx, &cache, &graph, &.{.{ .source = source, .info = info, .descriptor = asset_registry.descriptorForSource(source), .output_path = null, .cached_index = null }});

    try testing.expectEqual(@as(usize, 1), graph.dependencyCount(&source));
    const deps = graph.getDependencies(&source) orelse return error.MissingDependency;
    try testing.expectEqual(dep.hashPath(), deps.items[0]);
}

test "buildDependencyGraph refreshes stale cached dependency rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "main.frag",
        \\#include "new.glsl"
        \\void main() {}
        \\
    );

    const source = SourceFile.fromPath("main.frag");
    const old_dep = SourceFile.fromPath("old.glsl");
    const info = try source.getFileInfo(tmp.dir, testing.io);

    var cache = try Cache.init(testing.allocator, tmp.dir, ".");
    defer cache.deinit(testing.allocator);
    try cache.upsertDependencyRow(testing.allocator, source, .{
        .size = info.size + 1,
        .modified_ns = info.modified_ns,
    }, &.{old_dep});

    const ctx = CookContext{
        .io = testing.io,
        .source = tmp.dir,
        .output = tmp.dir,
        .output_path = ".",
        .force = false,
    };

    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try buildDependencyGraph(testing.allocator, &ctx, &cache, &graph, &.{.{ .source = source, .info = info, .descriptor = asset_registry.descriptorForSource(source), .output_path = null, .cached_index = null }});

    const row = cache.lookupDependencyRow(source) orelse return error.MissingDependencyRow;
    try testing.expect(row.isFresh(info));
    try testing.expectEqual(@as(usize, 1), row.dependencies.items.len);
    try testing.expectEqualStrings("new.glsl", row.dependencies.items[0].path);

    const deps = graph.getDependencies(&source) orelse return error.MissingDependency;
    try testing.expectEqual(SourceFile.fromPath("new.glsl").hashPath(), deps.items[0]);
}

test "validateUniqueOutputs rejects sources with the same cooked path" {
    const records = [_]SourceRecord{
        .{ .source = SourceFile.fromPath("textures/hero.png"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.png), .output_path = "textures/hero.ztex", .cached_index = null },
        .{ .source = SourceFile.fromPath("textures/hero.jpg"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.jpg), .output_path = "textures/hero.ztex", .cached_index = null },
    };
    try testing.expectError(error.DuplicateCookedOutput, validateUniqueOutputs(testing.allocator, &records));
}

test "validateUniqueOutputs allows repeated stems in different directories" {
    const records = [_]SourceRecord{
        .{ .source = SourceFile.fromPath("characters/hero.png"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.png), .output_path = "characters/hero.ztex", .cached_index = null },
        .{ .source = SourceFile.fromPath("ui/hero.png"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.png), .output_path = "ui/hero.ztex", .cached_index = null },
    };
    try validateUniqueOutputs(testing.allocator, &records);
}
