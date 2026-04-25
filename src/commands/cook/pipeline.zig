const std = @import("std");

const cache_session_mod = @import("cache_session.zig");
const planner = @import("planner.zig");
const Executor = @import("executor.zig").Executor;
const CookContext = @import("context.zig").CookContext;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const cook_metrics = @import("../cook_metrics.zig");
const CountingAllocator = @import("../../shared/counting_allocator.zig").CountingAllocator;

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

    var plan = try planner.build(allocator, ctx, &metrics);
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
    try executor.run(progress);

    const cache_write_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    try cache_session.persist(ctx.io);
    const cache_write_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.cache_write_ns = @intCast(cache_write_start.durationTo(cache_write_end).raw.nanoseconds);
    metrics.cache_bytes_written = cache_session_mod.CacheSession.cacheBytesWritten(ctx);

    const total_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.total_ns = @intCast(total_start.durationTo(total_end).raw.nanoseconds);
    metrics.ending_allocated_bytes = counting.current_requested_bytes;
    cook_metrics.markPeak(&metrics, counting.peak_requested_bytes);

    return metrics;
}
