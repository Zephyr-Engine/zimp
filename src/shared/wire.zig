const std = @import("std");

pub const max_asset_bytes: usize = 512 * 1024 * 1024;

pub fn enumFromInt(comptime E: type, raw: anytype) !E {
    return std.enums.fromInt(E, raw) orelse error.InvalidEnumValue;
}

pub fn readEnum(reader: *std.Io.Reader, comptime E: type, comptime Int: type) !E {
    return enumFromInt(E, try reader.takeInt(Int, .little));
}

pub fn checkedAddWithinLimit(total: *usize, amount: usize, limit: usize) !void {
    total.* = std.math.add(usize, total.*, amount) catch return error.AssetTooLarge;
    if (total.* > limit) return error.AssetTooLarge;
}

/// Write a u16 length prefix followed by the bytes.
pub fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeInt(u16, @intCast(value.len), .little);
    try writer.writeAll(value);
}

/// Read a string written by `writeString`. The caller owns the result.
pub fn readString(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const len = try reader.takeInt(u16, .little);
    const value = try allocator.alloc(u8, len);
    errdefer allocator.free(value);
    try reader.readSliceAll(value);
    return value;
}

test "writeString and readString round-trip" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeString(&writer, "cooked/mesh.zmesh");

    var reader = std.Io.Reader.fixed(writer.buffered());
    const value = try readString(std.testing.allocator, &reader);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("cooked/mesh.zmesh", value);
}

test "enumFromInt rejects invalid exhaustive enum values" {
    const E = enum(u8) { a = 0, b = 1 };
    try std.testing.expectEqual(E.b, try enumFromInt(E, 1));
    try std.testing.expectError(error.InvalidEnumValue, enumFromInt(E, 2));
}
