const std = @import("std");

const extractDependencies = @import("../../extractors/extractor.zig").extractDependencies;
const AssetScanner = @import("../../assets/asset_scanner.zig").AssetScanner;
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const Hash = @import("../../assets/source_file.zig").Hash;
const DepGraph = @import("../../assets/dependency_graph.zig").DepGraph;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const log = @import("../../logger.zig");
const CookContext = @import("context.zig").CookContext;

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

pub fn build(allocator: std.mem.Allocator, ctx: *const CookContext, metrics: *CookMetrics) !CookPlan {
    const scan_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const scanner = AssetScanner.init(allocator, ctx.io, ctx.source);
    var source_files = try scanner.scan();
    errdefer {
        for (source_files.items) |file| {
            allocator.free(file.path);
        }
        source_files.deinit(allocator);
    }
    const scan_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    metrics.scan_ns = @intCast(scan_start.durationTo(scan_end).raw.nanoseconds);
    metrics.assets_total = @intCast(source_files.items.len);

    const dep_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    var dep_graph = DepGraph.init(allocator);
    defer dep_graph.deinit();

    try buildDependencyGraph(allocator, ctx, &dep_graph, source_files.items);

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
    dep_graph: *DepGraph,
    source_files: []const SourceFile,
) !void {
    for (source_files) |source| {
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
    }
}

fn deinitReverse(allocator: std.mem.Allocator, reverse: *DependentsMap) void {
    var iter = reverse.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    reverse.deinit();
}
