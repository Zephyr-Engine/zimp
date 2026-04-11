const std = @import("std");

pub fn formatBytes(buf: []u8, size: u64) []const u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch unreachable;
    }

    if (size < 1024 * 1024) {
        const kb: f64 = @as(f64, @floatFromInt(size)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch unreachable;
    }

    if (size < 1024 * 1024 * 1024) {
        const mb: f64 = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch unreachable;
    }

    const gb: f64 = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1} GB", .{gb}) catch unreachable;
}

pub fn formatHash(buf: []u8, hash: u64) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>16}", .{hash}) catch unreachable;
}

pub fn formatTimestamp(buf: []u8, ns: i96) []const u8 {
    const secs: u64 = @intCast(@divTrunc(ns, std.time.ns_per_s));

    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
}

const testing = std.testing;

test "formatBytes: 0 bytes" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
}

test "formatBytes: small byte count" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
}

test "formatBytes: exactly 1023 bytes stays in bytes" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1023 B", formatBytes(&buf, 1023));
}

test "formatBytes: 1024 bytes shows as 1.0 KB" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1.0 KB", formatBytes(&buf, 1024));
}

test "formatBytes: 1536 bytes shows as 1.5 KB" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
}

test "formatBytes: 1 MB" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1.0 MB", formatBytes(&buf, 1024 * 1024));
}

test "formatBytes: 2.4 MB" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("2.4 MB", formatBytes(&buf, 2_516_582));
}

test "formatBytes: 1 GB" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1.0 GB", formatBytes(&buf, 1024 * 1024 * 1024));
}

test "formatHash: zero" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("0x0000000000000000", formatHash(&buf, 0));
}

test "formatHash: known value" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("0xa1b2c3d4e5f60718", formatHash(&buf, 0xa1b2c3d4e5f60718));
}

test "formatHash: max u64" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("0xffffffffffffffff", formatHash(&buf, std.math.maxInt(u64)));
}

test "formatTimestamp: Unix epoch" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatTimestamp(&buf, 0));
}

test "formatTimestamp: known date" {
    var buf: [24]u8 = undefined;
    const ns: i64 = 1775606400 * std.time.ns_per_s;
    try testing.expectEqualStrings("2026-04-08T00:00:00Z", formatTimestamp(&buf, ns));
}

test "formatTimestamp: with time component" {
    var buf: [24]u8 = undefined;
    const ns: i64 = (1775606400 + 12 * 3600 + 30 * 60 + 45) * std.time.ns_per_s;
    try testing.expectEqualStrings("2026-04-08T12:30:45Z", formatTimestamp(&buf, ns));
}
