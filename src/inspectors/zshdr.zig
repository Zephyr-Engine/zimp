const std = @import("std");

const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zshdr = @import("../formats/zshdr.zig");

fn stageName(stage: zshdr.ShaderStage) []const u8 {
    return switch (stage) {
        .vertex => "vertex",
        .fragment => "fragment",
        .compute => "compute",
    };
}

fn firstLine(source: []const u8) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, source, '\n')) |end|
        source[0..end]
    else
        source;
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn appendDecodedDefines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: zshdr.VariantKey, names: []const []const u8) !void {
    if (key.bits == 0) {
        try out.appendSlice(allocator, "(base)");
        return;
    }

    var first = true;
    for (names, 0..) |name, i| {
        if (!key.has(i)) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, name);
        first = false;
    }

    if (first) {
        try out.appendSlice(allocator, "(unknown bits)");
    }
}

fn formatKeyBits(buf: []u8, key: zshdr.VariantKey, variant_count: usize) []const u8 {
    const width = @max(variant_count, 1);
    std.debug.assert(buf.len >= width + 2);

    buf[0] = '0';
    buf[1] = 'b';
    for (0..width) |i| {
        const bit_index = width - 1 - i;
        buf[2 + i] = if (key.has(bit_index)) '1' else '0';
    }
    return buf[0 .. width + 2];
}

fn inspectZshdr(allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
    const version = try reader.takeInt(u32, .little);
    if (version != zshdr.ZSHDR_VERSION) return error.UnsupportedVersion;

    const stage: zshdr.ShaderStage = @enumFromInt(try reader.takeInt(u8, .little));
    const variant_name_count = try reader.takeInt(u16, .little);
    const include_count = try reader.takeInt(u16, .little);
    const permutation_count = try reader.takeInt(u32, .little);

    var total_file_size: u64 = zshdr.HEADER_SIZE;

    const variant_names = try readStringList(allocator, reader, variant_name_count, &total_file_size);
    defer freeStringList(allocator, variant_names);

    const includes = try readStringList(allocator, reader, include_count, &total_file_size);
    defer freeStringList(allocator, includes);

    log.info("zshdr", .{});
    log.info("  Magic:         {s}", .{zshdr.MAGIC});
    log.info("  Version:       {d}", .{version});
    log.info("  Stage:         {s}", .{stageName(stage)});
    log.info("  Format:        glsl_source", .{});
    log.info("  Variant names: {d}", .{variant_names.len});
    log.info("  Variant count: {d}", .{permutation_count});
    log.info("  Includes:      {d}", .{includes.len});

    if (variant_names.len > 0) {
        log.info("", .{});
        log.info("Variant Dimensions:", .{});
        for (variant_names, 0..) |name, i| {
            log.info("  bit {d}: {s}", .{ i, name });
        }
    }

    log.info("", .{});
    log.info("Variant Table:", .{});
    log.info("  {s: >5}  {s: <18}  {s: <28}  {s: >10}  {s}", .{ "index", "key", "defines", "payload", "first line" });
    log.info("  {s}", .{"-" ** 86});

    for (0..permutation_count) |i| {
        const key = zshdr.VariantKey.fromBits(try reader.takeInt(u32, .little));
        const source_len = try reader.takeInt(u32, .little);
        total_file_size += @sizeOf(u32) + @sizeOf(u32) + source_len;

        const source = try allocator.alloc(u8, source_len);
        defer allocator.free(source);
        try reader.readSliceAll(source);

        var key_buf: [66]u8 = undefined;
        var defines = std.ArrayList(u8).empty;
        defer defines.deinit(allocator);
        try appendDecodedDefines(&defines, allocator, key, variant_names);

        var size_buf: [16]u8 = undefined;
        log.info("  {d: >5}  {s: <18}  {s: <28}  {s: >10}  {s}", .{
            i,
            formatKeyBits(&key_buf, key, variant_names.len),
            defines.items,
            fmt.formatBytes(&size_buf, source_len),
            firstLine(source),
        });
    }

    log.info("", .{});
    var total_buf: [16]u8 = undefined;
    log.info("File Size Summary:", .{});
    log.info("  Total: {s: >10}", .{fmt.formatBytes(&total_buf, total_file_size)});
}

fn readStringList(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    count: usize,
    total_file_size: *u64,
) ![]const []const u8 {
    const items = try allocator.alloc([]const u8, count);
    errdefer allocator.free(items);

    var loaded: usize = 0;
    errdefer for (items[0..loaded]) |item| allocator.free(item);

    for (items) |*item| {
        const len = try reader.takeInt(u16, .little);
        total_file_size.* += @sizeOf(u16) + len;
        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);
        try reader.readSliceAll(bytes);
        item.* = bytes;
        loaded += 1;
    }

    return items;
}

fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZshdr };
}

const testing = std.testing;
const CookedShader = @import("../assets/cooked/shader.zig").CookedShader;

test "inspector returns a valid FormatInspector" {
    const insp = inspector();
    try testing.expectEqual(@as(*const fn (std.mem.Allocator, *std.Io.Reader) anyerror!void, inspectZshdr), insp.inspectFn);
}

test "inspectZshdr runs on a valid shader file" {
    const variant_names = try dupeStringList(testing.allocator, &.{ "SKINNED", "HAS_NORMAL_MAP" });
    const includes = try dupeStringList(testing.allocator, &.{"common.glsl"});
    const permutations = try testing.allocator.alloc(CookedShader.Permutation, 2);
    permutations[0] = .{
        .key = .base,
        .source = try testing.allocator.dupe(u8, "#version 330 core\nvoid main() {}\n"),
    };
    permutations[1] = .{
        .key = zshdr.VariantKey.base.with(0).with(1),
        .source = try testing.allocator.dupe(u8, "#version 330 core\n#define SKINNED\n#define HAS_NORMAL_MAP\nvoid main() {}\n"),
    };

    var cooked = CookedShader{
        .stage = .vertex,
        .variant_names = variant_names,
        .includes = includes,
        .permutations = permutations,
    };
    defer cooked.deinit(testing.allocator);

    var file_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&file_buf);
    try zshdr.write(&writer, cooked);

    var reader = std.Io.Reader.fixed(file_buf[zshdr.MAGIC.len..writer.end]);
    try inspectZshdr(testing.allocator, &reader);
}

fn dupeStringList(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(out);

    var loaded: usize = 0;
    errdefer for (out[0..loaded]) |item| allocator.free(item);

    for (strings, 0..) |value, i| {
        out[i] = try allocator.dupe(u8, value);
        loaded += 1;
    }

    return out;
}
