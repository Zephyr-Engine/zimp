const std = @import("std");
const log = @import("../logger.zig");

pub const CookMetrics = struct {
    schema_version: u32 = 1,

    assets_total: u32 = 0,
    assets_cooked: u32 = 0,
    assets_cached: u32 = 0,
    assets_hash_match: u32 = 0,
    assets_errored: u32 = 0,

    source_bytes_read: u64 = 0,
    source_bytes_hashed: u64 = 0,
    cooked_bytes_written: u64 = 0,
    cache_bytes_written: u64 = 0,

    scan_ns: u64 = 0,
    dependency_graph_ns: u64 = 0,
    cook_ns: u64 = 0,
    cache_write_ns: u64 = 0,
    total_ns: u64 = 0,

    peak_allocated_bytes: usize = 0,
    ending_allocated_bytes: usize = 0,
};

pub fn markPeak(metrics: *CookMetrics, allocated_bytes: usize) void {
    if (allocated_bytes > metrics.peak_allocated_bytes) {
        metrics.peak_allocated_bytes = allocated_bytes;
    }
}

pub fn logSummary(metrics: *const CookMetrics) void {
    var buf_scan: [32]u8 = undefined;
    var buf_dep: [32]u8 = undefined;
    var buf_cook: [32]u8 = undefined;
    var buf_cache: [32]u8 = undefined;
    var buf_total: [32]u8 = undefined;

    log.info("Cook stage timings: scan={s}, deps={s}, cook={s}, cache_write={s}, total={s}", .{
        fmtDuration(metrics.scan_ns, &buf_scan),
        fmtDuration(metrics.dependency_graph_ns, &buf_dep),
        fmtDuration(metrics.cook_ns, &buf_cook),
        fmtDuration(metrics.cache_write_ns, &buf_cache),
        fmtDuration(metrics.total_ns, &buf_total),
    });

    log.info("Cook I/O: source_read={d}B, source_hashed={d}B, cooked_written={d}B, cache_written={d}B", .{
        metrics.source_bytes_read,
        metrics.source_bytes_hashed,
        metrics.cooked_bytes_written,
        metrics.cache_bytes_written,
    });

    log.info("Cook memory: peak={d}B, end={d}B", .{
        metrics.peak_allocated_bytes,
        metrics.ending_allocated_bytes,
    });
}

pub fn emitCiJson(allocator: std.mem.Allocator, metrics: *const CookMetrics) !void {
    const json = try std.fmt.allocPrint(allocator, "{{\"schema_version\":{d},\"assets\":{{\"total\":{d},\"cooked\":{d},\"cached\":{d},\"hash_match\":{d},\"errored\":{d}}},\"io\":{{\"source_bytes_read\":{d},\"source_bytes_hashed\":{d},\"cooked_bytes_written\":{d},\"cache_bytes_written\":{d}}},\"timings_ns\":{{\"scan\":{d},\"dependency_graph\":{d},\"cook\":{d},\"cache_write\":{d},\"total\":{d}}},\"memory\":{{\"peak_allocated_bytes\":{d},\"ending_allocated_bytes\":{d}}}}}", .{
        metrics.schema_version,
        metrics.assets_total,
        metrics.assets_cooked,
        metrics.assets_cached,
        metrics.assets_hash_match,
        metrics.assets_errored,
        metrics.source_bytes_read,
        metrics.source_bytes_hashed,
        metrics.cooked_bytes_written,
        metrics.cache_bytes_written,
        metrics.scan_ns,
        metrics.dependency_graph_ns,
        metrics.cook_ns,
        metrics.cache_write_ns,
        metrics.total_ns,
        metrics.peak_allocated_bytes,
        metrics.ending_allocated_bytes,
    });
    defer allocator.free(json);

    std.debug.print("CI_METRICS_JSON {s}\n", .{json});
}

fn fmtDuration(nanoseconds: u64, buf: *[32]u8) []const u8 {
    if (nanoseconds >= std.time.ns_per_s) {
        const ms = @as(f64, @floatFromInt(nanoseconds)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{ms}) catch unreachable;
    }
    if (nanoseconds >= std.time.ns_per_ms) {
        return std.fmt.bufPrint(buf, "{d}ms", .{nanoseconds / std.time.ns_per_ms}) catch unreachable;
    }
    if (nanoseconds >= std.time.ns_per_us) {
        return std.fmt.bufPrint(buf, "{d}us", .{nanoseconds / std.time.ns_per_us}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}ns", .{nanoseconds}) catch unreachable;
}
