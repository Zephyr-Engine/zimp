const std = @import("std");

const CountingAllocator = @import("../../shared/counting_allocator.zig").CountingAllocator;
const meta_store_mod = @import("../../manifest/meta_store.zig");
const ProjectCookInfo = @import("context.zig").ProjectCookInfo;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const manifest_builder = @import("../../manifest/builder.zig");
const manifest_codec = @import("../../manifest/codec.zig");
const Publisher = @import("../../builtin/publisher.zig");
const cache_session_mod = @import("cache_session.zig");
const CookContext = @import("context.zig").CookContext;
const Cache = @import("../../cache/cache.zig").Cache;
const cook_metrics = @import("../cook_metrics.zig");
const model = @import("../../manifest/model.zig");
const Executor = @import("executor.zig").Executor;
const planner = @import("planner.zig");
const log = @import("../../logger.zig");

pub fn run(
    allocator: std.mem.Allocator,
    counting: *CountingAllocator,
    ctx: *const CookContext,
    progress: std.Progress.Node,
) !CookMetrics {
    var metrics: CookMetrics = .{};
    const total_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    {
        var cache_session = try cache_session_mod.CacheSession.open(allocator, ctx);
        defer cache_session.deinit(allocator);
        cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());

        {
            var plan = try planner.build(allocator, ctx, &cache_session.cache, &metrics);
            defer plan.deinit(allocator);
            cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());

            const source_files = try planner.sourceSlice(allocator, plan.records.items);
            defer allocator.free(source_files);
            cache_session.pruneDeleted(allocator, source_files);

            var executor = Executor.init(
                allocator,
                ctx,
                &metrics,
                &cache_session.cache,
                plan.records.items,
                plan.dependencies,
                plan.dependents,
                counting,
            );
            try executor.run(ctx.io, progress);

            const cache_write_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
            metrics.cache_bytes_written = try cache_session.persist(allocator, ctx);
            const cache_write_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
            metrics.cache_write_ns = @intCast(cache_write_start.durationTo(cache_write_end).raw.nanoseconds);

            if (ctx.project) |proj| {
                var publisher = try Publisher.publish(allocator, ctx);
                defer publisher.deinit(allocator);

                const builtin_entries = try publisher.manifestEntries(allocator);
                defer allocator.free(builtin_entries);

                try buildAndWriteManifest(
                    allocator,
                    ctx,
                    proj,
                    &cache_session.cache,
                    plan.orphan_sidecars.items,
                    builtin_entries,
                );
            }
        }

        metrics.pipeline_live_bytes = counting.currentRequestedBytes();
        cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());
    }

    metrics.ending_allocated_bytes = counting.currentRequestedBytes();
    const total_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.total_ns = @intCast(total_start.durationTo(total_end).raw.nanoseconds);
    cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());

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
    orphan_sidecars: []const []const u8,
    builtin_entries: []const model.AssetManifestEntry,
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
        .builtin_entries = builtin_entries,
    }, &stats);
    defer manifest.deinit();

    try manifest_codec.writeToDir(allocator, ctx.io, proj.root_dir, proj.manifest_path, &manifest);
    const sidecars_written = try metas.flush(allocator);

    warnOrphanedSidecars(orphan_sidecars);

    log.info("Asset manifest: {d} entries ({d} builtin, {d} sidecar, {d} derived, {d} new); {d} sidecar(s) written", .{
        stats.entries,
        stats.builtin_entries,
        stats.ids_from_sidecar,
        stats.ids_derived,
        stats.ids_new,
        sidecars_written,
    });
}

/// A sidecar whose source file is gone is authored identity with nothing to
/// identify — warn, never delete (the user may be mid-rename or mid-revert).
fn warnOrphanedSidecars(sidecars: []const []const u8) void {
    for (sidecars) |sidecar| {
        const source = sidecar[0 .. sidecar.len - ".zmeta".len];
        log.warn("orphaned sidecar '{s}': source file '{s}' no longer exists. If the asset was renamed, move the sidecar with it to preserve its id; if it was deleted, delete the sidecar too.", .{ sidecar, source });
    }
}
