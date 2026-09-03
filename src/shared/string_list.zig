const std = @import("std");

/// Deep-copy a list of strings. On failure every string duplicated so far is
/// freed, so the caller never has to unwind a partial list.
pub fn dupeStringList(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
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

/// Free a list produced by `dupeStringList`, strings first, then the backing array.
pub fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

const testing = std.testing;

test "dupeStringList deep-copies every entry" {
    const src = [_][]const u8{ "alpha", "beta" };
    const copy = try dupeStringList(testing.allocator, &src);
    defer freeStringList(testing.allocator, copy);

    try testing.expectEqual(@as(usize, 2), copy.len);
    try testing.expectEqualStrings("alpha", copy[0]);
    try testing.expectEqualStrings("beta", copy[1]);
    try testing.expect(copy[0].ptr != src[0].ptr);
}

test "dupeStringList frees partial work when an allocation fails" {
    const src = [_][]const u8{ "alpha", "beta", "gamma" };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    try testing.expectError(error.OutOfMemory, dupeStringList(failing.allocator(), &src));
}

test "dupeStringList handles the empty list" {
    const copy = try dupeStringList(testing.allocator, &.{});
    defer freeStringList(testing.allocator, copy);
    try testing.expectEqual(@as(usize, 0), copy.len);
}
