const std = @import("std");

const asset = @import("../assets/asset.zig");
const AssetType = asset.AssetType;
const SourceFile = @import("../assets/source_file.zig").SourceFile;

pub const DependencyExtractor = struct {
    extractFn: *const fn (
        source: *const SourceFile,
        dir: std.Io.Dir,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) anyerror![]const SourceFile,
    asset_type: AssetType,

    pub fn extract(
        self: DependencyExtractor,
        source: *const SourceFile,
        dir: std.Io.Dir,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) ![]const SourceFile {
        return self.extractFn(source, dir, io, allocator);
    }
};

const testing = std.testing;

var test_called: bool = false;

fn stubExtract(
    _: *const SourceFile,
    _: std.Io.Dir,
    _: std.Io,
    _: std.mem.Allocator,
) anyerror![]const SourceFile {
    test_called = true;
    return &.{};
}

fn failingExtract(
    _: *const SourceFile,
    _: std.Io.Dir,
    _: std.Io,
    _: std.mem.Allocator,
) anyerror![]const SourceFile {
    return error.TestExtractFailed;
}

test "DependencyExtractor.extract calls the provided function pointer" {
    test_called = false;
    const ex = DependencyExtractor{ .extractFn = stubExtract, .asset_type = .mesh };

    const sf = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    const deps = try ex.extract(&sf, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(deps);

    try testing.expect(test_called);
}

test "DependencyExtractor.extract propagates errors from extractFn" {
    const ex = DependencyExtractor{ .extractFn = failingExtract, .asset_type = .mesh };

    const sf = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    try testing.expectError(
        error.TestExtractFailed,
        ex.extract(&sf, std.Io.Dir.cwd(), testing.io, testing.allocator),
    );
}

test "DependencyExtractor struct contains extractFn and asset_type" {
    try testing.expect(@hasField(DependencyExtractor, "extractFn"));
    try testing.expect(@hasField(DependencyExtractor, "asset_type"));
}
