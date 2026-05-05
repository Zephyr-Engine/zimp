const std = @import("std");

const FORMAT_MAGIC = @import("../shared/constants.zig").FORMAT_MAGIC;

pub const FormatInspector = struct {
    inspectFn: *const fn (
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) anyerror!void,

    pub fn inspect(self: FormatInspector, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
        return self.inspectFn(allocator, reader);
    }
};

const zamesh_inspector = @import("../inspectors/zmesh.zig").inspector();
const zatex_inspector = @import("../inspectors/ztex.zig").inspector();
const zcache_inspector = @import("../inspectors/zcache.zig").inspector();
const zshdr_inspector = @import("../inspectors/zshdr.zig").inspector();
const zamat_inspector = @import("../inspectors/zamat.zig").inspector();

pub const inspector_registry = std.StaticStringMap(FormatInspector).initComptime(.{
    .{ FORMAT_MAGIC.ZMESH, zamesh_inspector },
    .{ FORMAT_MAGIC.ZACHE, zcache_inspector },
    .{ FORMAT_MAGIC.ZATEX, zatex_inspector },
    .{ FORMAT_MAGIC.ZSHDR, zshdr_inspector },
    .{ FORMAT_MAGIC.ZAMAT, zamat_inspector },
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
    try testing.expect(inspector_registry.get(FORMAT_MAGIC.ZMESH) != null);
}

test "inspector_registry contains ZSHDR magic" {
    try testing.expect(inspector_registry.get(FORMAT_MAGIC.ZSHDR) != null);
}

test "inspector_registry contains ZAMAT magic" {
    try testing.expect(inspector_registry.get(FORMAT_MAGIC.ZAMAT) != null);
}

test "inspector_registry returns null for unknown magic" {
    try testing.expectEqual(@as(?FormatInspector, null), inspector_registry.get("NOPE!"));
}

test "inspector_registry maps ZMESH to zamesh_inspector" {
    const found = inspector_registry.get(FORMAT_MAGIC.ZMESH).?;
    try testing.expectEqual(zamesh_inspector.inspectFn, found.inspectFn);
}

test "inspector_registry maps ZSHDR to zshdr_inspector" {
    const found = inspector_registry.get(FORMAT_MAGIC.ZSHDR).?;
    try testing.expectEqual(zshdr_inspector.inspectFn, found.inspectFn);
}
