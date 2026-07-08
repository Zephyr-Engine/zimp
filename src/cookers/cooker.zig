const std = @import("std");

const asset = @import("../assets/asset.zig");
const path_helpers = @import("../path.zig");
const AssetType = asset.AssetType;

pub const Cooker = struct {
    cookFn: *const fn (
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        file_path: []const u8,
        writer: *std.Io.Writer,
    ) anyerror!void,
    asset_type: AssetType,
    outputPathFn: ?*const fn (
        allocator: std.mem.Allocator,
        file_path: []const u8,
        asset_type: AssetType,
    ) anyerror![]u8 = null,

    pub fn cook(
        self: Cooker,
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        file_path: []const u8,
        writer: *std.Io.Writer,
    ) !void {
        return self.cookFn(allocator, io, source_dir, file_path, writer);
    }

    pub fn outputPath(
        self: Cooker,
        allocator: std.mem.Allocator,
        file_path: []const u8,
    ) ![]u8 {
        if (self.outputPathFn) |path_fn| {
            return path_fn(allocator, file_path, self.asset_type);
        }
        return path_helpers.cookedOutput(allocator, file_path, self.asset_type);
    }
};

const testing = std.testing;

var test_called: bool = false;

fn stubCook(_: std.mem.Allocator, _: std.Io, _: std.Io.Dir, _: []const u8, _: *std.Io.Writer) anyerror!void {
    test_called = true;
}

fn failingCook(_: std.mem.Allocator, _: std.Io, _: std.Io.Dir, _: []const u8, _: *std.Io.Writer) anyerror!void {
    return error.TestCookFailed;
}

test "Cooker.cook calls the provided function pointer" {
    test_called = false;
    const cooker = Cooker{ .cookFn = stubCook, .asset_type = .mesh };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    try cooker.cook(testing.allocator, testing.io, std.Io.Dir.cwd(), "", &writer);

    try testing.expect(test_called);
}

test "Cooker.cook propagates errors from cookFn" {
    const cooker = Cooker{ .cookFn = failingCook, .asset_type = .mesh };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.TestCookFailed, cooker.cook(testing.allocator, testing.io, std.Io.Dir.cwd(), "", &writer));
}

test "Cooker struct contains cookFn and asset_type" {
    try testing.expect(@sizeOf(Cooker) > @sizeOf(*const fn (std.mem.Allocator, std.Io, std.Io.Dir, []const u8, *std.Io.Writer) anyerror!void));
    try testing.expect(@hasField(Cooker, "cookFn"));
    try testing.expect(@hasField(Cooker, "asset_type"));
}
