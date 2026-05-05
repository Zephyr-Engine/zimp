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

const mesh_extractor = @import("mesh.zig").extractor();
const shader_extractor = @import("shader.zig").extractor();
const material_extractor = @import("material.zig").extractor();

pub const extractor_registry = std.EnumArray(AssetType, ?DependencyExtractor).init(.{
    .mesh = mesh_extractor,
    .shader = shader_extractor,
    .texture = null,
    .material = material_extractor,
    .unknown = null,
});

comptime {
    for (std.meta.fields(AssetType)) |field| {
        const at: AssetType = @enumFromInt(field.value);
        if (extractor_registry.get(at)) |ex| {
            if (ex.asset_type != at) {
                @compileError("DependencyExtractor for asset type '" ++ field.name ++
                    "' has asset_type that does not match registry key");
            }
        }
    }
}

pub fn extractDependencies(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    if (extractor_registry.get(source.assetType)) |e| {
        return e.extract(source, dir, io, allocator);
    }
    return &.{};
}

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

test "extractor_registry contains mesh" {
    try testing.expect(extractor_registry.get(.mesh) != null);
}

test "extractor_registry contains shader" {
    try testing.expect(extractor_registry.get(.shader) != null);
}

test "extractor_registry returns null for texture" {
    try testing.expectEqual(@as(?DependencyExtractor, null), extractor_registry.get(.texture));
}

test "extractor_registry returns null for unknown" {
    try testing.expectEqual(@as(?DependencyExtractor, null), extractor_registry.get(.unknown));
}

test "extractDependencies returns empty slice for texture" {
    const sf = SourceFile{ .path = "a.png", .extension = .png, .assetType = .texture };
    const deps = try extractDependencies(&sf, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "extractDependencies returns empty slice for unknown" {
    const sf = SourceFile{ .path = "a.xyz", .extension = .other, .assetType = .unknown };
    const deps = try extractDependencies(&sf, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "extractDependencies routes to mesh extractor" {
    const sf = SourceFile{ .path = "a.glb", .extension = .glb, .assetType = .mesh };
    const deps = try extractDependencies(&sf, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "extractDependencies routes to shader extractor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "a.vert", .{});
    file.close(testing.io);
    const sf = SourceFile{ .path = "a.vert", .extension = .vert, .assetType = .shader };
    const deps = try extractDependencies(&sf, tmp.dir, testing.io, testing.allocator);
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}
