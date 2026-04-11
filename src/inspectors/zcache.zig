const std = @import("std");
const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const cache = @import("../cache/cache.zig");
const AssetType = @import("../assets/asset.zig").AssetType;

const ENTRY_SIZE: u32 = 6 * @sizeOf(u64) + @sizeOf(i64) + @sizeOf(u16);

pub const InspectError = error{
    UnsupportedVersion,
};

fn readHeader(reader: *std.Io.Reader) !cache.CacheHeader {
    const version = try reader.takeInt(u16, .little);
    if (version != cache.VERSION) {
        return InspectError.UnsupportedVersion;
    }

    const entry_count = try reader.takeInt(u32, .little);

    return .{
        .version = version,
        .entry_count = entry_count,
    };
}

fn readEntry(reader: *std.Io.Reader) !cache.CacheEntry {
    return .{
        .source_path_hash = try reader.takeInt(u64, .little),
        .content_hash = try reader.takeInt(u64, .little),
        .source_size = try reader.takeInt(u64, .little),
        .source_mtime = try reader.takeInt(i96, .little),
        .cooked_path_hash = try reader.takeInt(u64, .little),
        .cooked_size = try reader.takeInt(u64, .little),
        .asset_type = @enumFromInt(try reader.takeInt(u16, .little)),
    };
}

fn inspectZCache(_: std.mem.Allocator, reader: *std.Io.Reader) !void {
    const header = try readHeader(reader);

    log.info("zcache v{d}", .{header.version});
    log.info("  Entries: {d}", .{header.entry_count});

    log.info("", .{});
    log.info("Entries:", .{});
    log.info("  {s: >5}  {s: >18}  {s: >18}  {s: >10}  {s: >22}  {s: >18}  {s: >10}  {s: <8}", .{
        "index", "source_hash", "content_hash", "src_size", "last_updated", "cooked_hash", "cook_size", "type",
    });
    log.info("  {s}", .{"-" ** 119});

    var total_source_size: u64 = 0;
    var total_cooked_size: u64 = 0;

    for (0..header.entry_count) |i| {
        const entry = try readEntry(reader);

        var hash1: [20]u8 = undefined;
        var hash2: [20]u8 = undefined;
        var hash3: [20]u8 = undefined;
        var size1: [16]u8 = undefined;
        var size2: [16]u8 = undefined;
        var ts: [24]u8 = undefined;

        log.info("  {d: >5}  {s: >18}  {s: >18}  {s: >10}  {s: >22}  {s: >18}  {s: >10}  {s: <8}", .{
            i,
            fmt.formatHash(&hash1, entry.source_path_hash),
            fmt.formatHash(&hash2, entry.content_hash),
            fmt.formatBytes(&size1, entry.source_size),
            fmt.formatTimestamp(&ts, entry.source_mtime),
            fmt.formatHash(&hash3, entry.cooked_path_hash),
            fmt.formatBytes(&size2, entry.cooked_size),
            @tagName(entry.asset_type),
        });

        total_source_size += entry.source_size;
        total_cooked_size += entry.cooked_size;
    }

    log.info("", .{});
    log.info("Summary:", .{});

    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    var buf3: [16]u8 = undefined;

    log.info("  Header:            {s: >10}", .{fmt.formatBytes(&buf1, cache.HEADER_SIZE)});
    log.info("  Entry table:       {s: >10}", .{fmt.formatBytes(&buf2, @as(u64, header.entry_count) * ENTRY_SIZE)});
    log.info("  Total source size: {s: >10}", .{fmt.formatBytes(&buf3, total_source_size)});

    if (total_cooked_size > 0 and total_source_size > 0) {
        const ratio: f64 = @as(f64, @floatFromInt(total_cooked_size)) / @as(f64, @floatFromInt(total_source_size));
        log.info("  Total cooked size: {s: >10} ({d:.1}x)", .{ fmt.formatBytes(&buf1, total_cooked_size), ratio });
    } else {
        log.info("  Total cooked size: {s: >10}", .{fmt.formatBytes(&buf1, total_cooked_size)});
    }
}

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZCache };
}

const testing = std.testing;

test "inspector returns a valid FormatInspector" {
    const insp = inspector();
    try testing.expectEqual(@as(*const fn (std.mem.Allocator, *std.Io.Reader) anyerror!void, inspectZCache), insp.inspectFn);
}

test "inspector can be called through FormatInspector trait" {
    const insp = inspector();

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZcache(&writer, .{});

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    try insp.inspect(testing.allocator, &reader);
}

test "readHeader parses a valid zcache header" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZcache(&writer, .{});

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    const header = try readHeader(&reader);

    try testing.expectEqual(cache.VERSION, header.version);
    try testing.expectEqual(@as(u32, 2), header.entry_count);
}

test "readHeader returns UnsupportedVersion for wrong version" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, 999, .little);
    try writer.writeAll(&(.{0} ** 50));

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    try testing.expectError(InspectError.UnsupportedVersion, readHeader(&reader));
}

test "readHeader accepts zero entries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, cache.VERSION, .little);
    try writer.writeInt(u32, 0, .little);

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    const header = try readHeader(&reader);
    try testing.expectEqual(@as(u32, 0), header.entry_count);
}

test "readEntry parses entry fields correctly" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writer.writeInt(u64, 0xAABBCCDD, .little);
    try writer.writeInt(u64, 0x11223344, .little);
    try writer.writeInt(u64, 1024, .little);
    try writer.writeInt(i64, 1775606400 * std.time.ns_per_s, .little);
    try writer.writeInt(u64, 0x55667788, .little);
    try writer.writeInt(u64, 512, .little);
    try writer.writeInt(u16, @intFromEnum(AssetType.mesh), .little);

    var reader = std.Io.Reader.fixed(buf[0..writer.end]);
    const entry = try readEntry(&reader);

    try testing.expectEqual(@as(u64, 0xAABBCCDD), entry.source_path_hash);
    try testing.expectEqual(@as(u64, 0x11223344), entry.content_hash);
    try testing.expectEqual(@as(u64, 1024), entry.source_size);
    try testing.expectEqual(@as(u64, 0x55667788), entry.cooked_path_hash);
    try testing.expectEqual(@as(u64, 512), entry.cooked_size);
    try testing.expectEqual(AssetType.mesh, entry.asset_type);
}

test "inspectZCache runs without error on valid zcache" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTestZcache(&writer, .{});

    var reader = std.Io.Reader.fixed(buf[cache.MAGIC.len..writer.end]);
    try inspectZCache(testing.allocator, &reader);
}

const TestZcacheOpts = struct {
    entry_count: u32 = 2,
};

fn writeTestZcache(writer: *std.Io.Writer, opts: TestZcacheOpts) !void {
    try writer.writeAll(cache.MAGIC);
    try writer.writeInt(u16, cache.VERSION, .little);
    try writer.writeInt(u32, opts.entry_count, .little);

    for (0..opts.entry_count) |i| {
        try writer.writeInt(u64, 0x1000 + i, .little); // source_path_hash
        try writer.writeInt(u64, 0x2000 + i, .little); // content_hash
        try writer.writeInt(u64, 4096 * (i + 1), .little); // source_size
        try writer.writeInt(i64, 1775606400 * std.time.ns_per_s, .little); // source_mtime
        try writer.writeInt(u64, 0x3000 + i, .little); // cooked_path_hash
        try writer.writeInt(u64, 2048 * (i + 1), .little); // cooked_size
        try writer.writeInt(u16, @intFromEnum(AssetType.mesh), .little); // asset_type
    }
}
