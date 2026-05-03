const std = @import("std");

const extractDependencies = @import("../../extractors/extractor.zig").extractDependencies;
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

pub const CookPlan = struct {
    source_files: std.ArrayList(SourceFile),
    levels: [][]SourceFile,
    reverse: DependentsMap,

    pub fn deinit(self: *CookPlan, allocator: std.mem.Allocator) void {
        for (self.source_files.items) |file| {
            allocator.free(file.path);
        }
        self.source_files.deinit(allocator);

        DepGraph.freeLevels(allocator, self.levels);

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
    var source_files = try scanner.scan();
    errdefer {
        for (source_files.items) |file| {
            allocator.free(file.path);
        }
        source_files.deinit(allocator);
    }

    const generated_materials = try material_generator.generateForSources(allocator, ctx.io, ctx.source, source_files.items);
    if (generated_materials > 0) {
        log.debug("Generated {d} material source file(s), rescanning assets", .{generated_materials});
        scanner.deinit(&source_files);
        source_files = try scanner.scan();
    }
    const scan_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    metrics.scan_ns = @intCast(scan_start.durationTo(scan_end).raw.nanoseconds);
    metrics.assets_total = @intCast(source_files.items.len);

    const dep_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    var dep_graph = DepGraph.init(allocator);
    defer dep_graph.deinit();

    try buildDependencyGraph(allocator, ctx, cache, &dep_graph, source_files.items);

    const dep_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.dependency_graph_ns = @intCast(dep_start.durationTo(dep_end).raw.nanoseconds);

    log.debug("Built dependency graph: {d} edge(s) across {d} source file(s)", .{
        dep_graph.totalDependencyCount(),
        source_files.items.len,
    });

    const levels = try dep_graph.cookLevels(source_files.items);
    errdefer DepGraph.freeLevels(allocator, levels);

    var reverse = try dep_graph.buildReverse(allocator);
    errdefer deinitReverse(allocator, &reverse);

    return .{
        .source_files = source_files,
        .levels = levels,
        .reverse = reverse,
    };
}

fn buildDependencyGraph(
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *Cache,
    dep_graph: *DepGraph,
    source_files: []const SourceFile,
) !void {
    for (source_files) |source| {
        const info = source.getFileInfo(ctx.source, ctx.io) catch |err| {
            log.warn("Failed to stat '{s}' while building dependency graph: {s}", .{ source.path, @errorName(err) });
            continue;
        };

        if (cache.lookupDependencyRow(source)) |row| {
            if (row.isFresh(info)) {
                const from = source.hashPath();
                for (row.dependencies.items) |dep| {
                    try dep_graph.addDependency(from, dep.path_hash);
                }
                continue;
            }
        }

        const deps = extractDependencies(&source, ctx.source, ctx.io, allocator) catch |err| {
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

        try cache.upsertDependencyRow(allocator, source, info, deps);
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

    try buildDependencyGraph(testing.allocator, &ctx, &cache, &graph, &.{source});

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

    try buildDependencyGraph(testing.allocator, &ctx, &cache, &graph, &.{source});

    const row = cache.lookupDependencyRow(source) orelse return error.MissingDependencyRow;
    try testing.expect(row.isFresh(info));
    try testing.expectEqual(@as(usize, 1), row.dependencies.items.len);
    try testing.expectEqualStrings("new.glsl", row.dependencies.items[0].path);

    const deps = graph.getDependencies(&source) orelse return error.MissingDependency;
    try testing.expectEqual(SourceFile.fromPath("new.glsl").hashPath(), deps.items[0]);
}
