const std = @import("std");

pub const FormatInspector = struct {
    inspectFn: *const fn (
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) anyerror!void,

    pub fn inspect(self: FormatInspector, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
        return self.inspectFn(allocator, reader);
    }
};

const zmesh_magic = @import("../formats/zmesh.zig").MAGIC;
const zamesh_inspector = @import("../inspectors/zmesh.zig").inspector();

pub const inspector_registry = std.StaticStringMap(FormatInspector).initComptime(.{
    .{ zmesh_magic, zamesh_inspector },
});

const testing = std.testing;

var test_called: bool = false;

fn stubInspect(_: std.mem.Allocator, _: *std.Io.Reader) anyerror!void {
    test_called = true;
}

fn failingInspect(_: std.mem.Allocator, _: *std.Io.Reader) anyerror!void {
    return error.TestInspectFailed;
}

test "FormatInspector.inspect calls the provided function pointer" {
    test_called = false;
    const inspector = FormatInspector{ .inspectFn = stubInspect };

    var buf: [1]u8 = .{0};
    var reader = std.Io.Reader.fixed(&buf);
    try inspector.inspect(testing.allocator, &reader);

    try testing.expect(test_called);
}

test "FormatInspector.inspect propagates errors from inspectFn" {
    const inspector = FormatInspector{ .inspectFn = failingInspect };

    var buf: [1]u8 = .{0};
    var reader = std.Io.Reader.fixed(&buf);
    try testing.expectError(error.TestInspectFailed, inspector.inspect(testing.allocator, &reader));
}

test "FormatInspector struct size is one pointer wide" {
    try testing.expectEqual(@sizeOf(*const fn (std.mem.Allocator, *std.Io.Reader) anyerror!void), @sizeOf(FormatInspector));
}

test "inspector_registry contains ZMESH magic" {
    try testing.expect(inspector_registry.get(zmesh_magic) != null);
}

test "inspector_registry returns null for unknown magic" {
    try testing.expectEqual(@as(?FormatInspector, null), inspector_registry.get("NOPE!"));
}

test "inspector_registry maps ZMESH to zamesh_inspector" {
    const found = inspector_registry.get(zmesh_magic).?;
    try testing.expectEqual(zamesh_inspector.inspectFn, found.inspectFn);
}
