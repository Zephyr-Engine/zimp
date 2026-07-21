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

test "enumFromInt rejects invalid exhaustive enum values" {
    const E = enum(u8) { a = 0, b = 1 };
    try std.testing.expectEqual(E.b, try enumFromInt(E, 1));
    try std.testing.expectError(error.InvalidEnumValue, enumFromInt(E, 2));
}
