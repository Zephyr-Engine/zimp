const std = @import("std");

const path_helpers = @import("../path.zig");
const SourceFile = @import("../assets/source_file.zig").SourceFile;

pub const CookInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source: SourceFile,
    bytes: []const u8,
    writer: *std.Io.Writer,
};

pub const Cooker = struct {
    cook_fn: *const fn (input: *const CookInput) anyerror!void,
    output_path_fn: ?*const fn (
        allocator: std.mem.Allocator,
        source: SourceFile,
    ) anyerror![]u8 = null,

    pub fn cook(self: Cooker, input: *const CookInput) !void {
        return self.cook_fn(input);
    }

    pub fn outputPath(
        self: Cooker,
        allocator: std.mem.Allocator,
        source: SourceFile,
    ) ![]u8 {
        if (self.output_path_fn) |path_fn| {
            return path_fn(allocator, source);
        }
        return path_helpers.cookedOutput(allocator, source.path, source.assetKind() orelse return error.UnsupportedAssetKind);
    }
};

const testing = std.testing;

var test_called: bool = false;

fn stubCook(_: *const CookInput) anyerror!void {
    test_called = true;
}

fn failingCook(_: *const CookInput) anyerror!void {
    return error.TestCookFailed;
}

test "Cooker.cook calls the provided function pointer" {
    test_called = false;
    const cooker = Cooker{ .cook_fn = stubCook };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    const input = CookInput{ .allocator = testing.allocator, .io = testing.io, .source_dir = std.Io.Dir.cwd(), .source = SourceFile.fromPath(""), .bytes = "", .writer = &writer };
    try cooker.cook(&input);

    try testing.expect(test_called);
}

test "Cooker.cook propagates errors from cook_fn" {
    const cooker = Cooker{ .cook_fn = failingCook };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    const input = CookInput{ .allocator = testing.allocator, .io = testing.io, .source_dir = std.Io.Dir.cwd(), .source = SourceFile.fromPath(""), .bytes = "", .writer = &writer };
    try testing.expectError(error.TestCookFailed, cooker.cook(&input));
}
