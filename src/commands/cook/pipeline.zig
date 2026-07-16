const std = @import("std");

const cache_session_mod = @import("cache_session.zig");
const planner = @import("planner.zig");
const Executor = @import("executor.zig").Executor;
const CookContext = @import("context.zig").CookContext;
const ProjectCookInfo = @import("context.zig").ProjectCookInfo;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const cook_metrics = @import("../cook_metrics.zig");
const CountingAllocator = @import("../../shared/counting_allocator.zig").CountingAllocator;
const Cache = @import("../../cache/cache.zig").Cache;
const manifest_builder = @import("../../manifest/builder.zig");
const manifest_codec = @import("../../manifest/codec.zig");
const meta_store_mod = @import("../../manifest/meta_store.zig");
const meta_mod = @import("../../manifest/meta.zig");
const log = @import("../../logger.zig");

pub fn run(
    allocator: std.mem.Allocator,
    counting: *CountingAllocator,
    ctx: *const CookContext,
    progress: std.Progress.Node,
) !CookMetrics {
    var metrics: CookMetrics = .{};
    const total_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    var cache_session = try cache_session_mod.CacheSession.open(allocator, ctx);
    defer cache_session.deinit(allocator);
    cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

    var plan = try planner.build(allocator, ctx, &cache_session.cache, &metrics);
    defer plan.deinit(allocator);
    cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

    cache_session.pruneDeleted(allocator, plan.source_files.items);

    var executor = Executor.init(
        allocator,
        ctx,
        &metrics,
        &cache_session.cache,
        plan.levels,
        &plan.reverse,
        counting,
    );
    try executor.run(ctx.io, progress);

    const cache_write_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    try cache_session.persist(allocator, ctx.io);
    const cache_write_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.cache_write_ns = @intCast(cache_write_start.durationTo(cache_write_end).raw.nanoseconds);
    metrics.cache_bytes_written = cache_session_mod.CacheSession.cacheBytesWritten(ctx);

    if (ctx.project) |proj| {
        try buildAndWriteManifest(allocator, ctx, proj, &cache_session.cache);
    }

    const total_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.total_ns = @intCast(total_start.durationTo(total_end).raw.nanoseconds);
    metrics.ending_allocated_bytes = counting.current_requested_bytes;
    cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

    return metrics;
}

/// Project-mode epilogue: resolve durable asset identity from the post-cook
/// cache, write `assets.zmanifest`, and only then flush `.zmeta` sidecars —
/// so a failed manifest build/write never persists partial identity.
fn buildAndWriteManifest(
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    proj: ProjectCookInfo,
    cache: *const Cache,
) !void {
    var metas = meta_store_mod.MetaStore.init(allocator, ctx.io, ctx.source);
    defer metas.deinit();

    const random_source: std.Random.IoSource = .{ .io = ctx.io };
    var stats = manifest_builder.BuildStats{};
    var manifest = try manifest_builder.build(allocator, .{
        .project_id = proj.project_id,
        .cache = cache,
        .metas = &metas,
        .io = ctx.io,
        .random = random_source.interface(),
    }, &stats);
    defer manifest.deinit();

    try manifest_codec.writeToDir(allocator, ctx.io, proj.root_dir, proj.manifest_path, &manifest);
    const sidecars_written = try metas.flush(allocator);

    warnOrphanedSidecars(allocator, ctx, &manifest);

    log.info("Asset manifest: {d} entries ({d} sidecar, {d} derived, {d} new); {d} sidecar(s) written", .{
        stats.entries,
        stats.ids_from_sidecar,
        stats.ids_derived,
        stats.ids_new,
        sidecars_written,
    });
}

/// A sidecar whose source file is gone is authored identity with nothing to
/// identify — warn, never delete (the user may be mid-rename or mid-revert).
fn warnOrphanedSidecars(allocator: std.mem.Allocator, ctx: *const CookContext, manifest: *const @import("../../manifest/model.zig").AssetManifest) void {
    warnOrphansInDir(allocator, ctx, manifest, ctx.source, "") catch |err| {
        log.warn("orphaned-sidecar sweep failed: {s}", .{@errorName(err)});
    };
}

fn warnOrphansInDir(
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    manifest: *const @import("../../manifest/model.zig").AssetManifest,
    dir: std.Io.Dir,
    prefix: []const u8,
) !void {
    var iter = dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (entry.kind == .directory) {
            const subdir = try std.Io.Dir.openDir(dir, ctx.io, entry.name, .{ .iterate = true });
            defer subdir.close(ctx.io);
            const subprefix = try std.fs.path.join(allocator, &.{ prefix, entry.name });
            defer allocator.free(subprefix);
            try warnOrphansInDir(allocator, ctx, manifest, subdir, subprefix);
            continue;
        }
        if (entry.kind != .file or !meta_mod.isMetaPath(entry.name)) continue;

        const source_name = entry.name[0 .. entry.name.len - meta_mod.meta_extension.len];
        dir.access(ctx.io, source_name, .{}) catch {
            const source_path = if (prefix.len > 0)
                try std.fs.path.join(allocator, &.{ prefix, source_name })
            else
                try allocator.dupe(u8, source_name);
            defer allocator.free(source_path);
            log.warn("orphaned sidecar '{s}{s}': source file '{s}' no longer exists. " ++
                "If the asset was renamed, move the sidecar with it to preserve its id; " ++
                "if it was deleted, delete the sidecar too.", .{ source_path, meta_mod.meta_extension, source_path });
        };
    }
}
