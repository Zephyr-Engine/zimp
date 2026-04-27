const std = @import("std");

const DependencyExtractor = @import("extractor.zig").DependencyExtractor;
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const Gltf = @import("../parsers/gltf/gltf_json_parser.zig").Gltf;
const gltf_document = @import("../parsers/gltf/document.zig");
const file_read = @import("../shared/file_read.zig");

pub fn extractor() DependencyExtractor {
    return .{ .extractFn = extractMeshDeps, .asset_type = .mesh };
}

fn extractMeshDeps(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    if (source.extension != .gltf) {
        return &.{};
    }

    const file_result = try file_read.readFileAllocChunked(allocator, io, dir, source.path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    var gltf = try Gltf.parse(file_result.bytes, allocator);
    defer gltf.deinit();

    var dep_paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dep_paths.items) |path| allocator.free(path);
        dep_paths.deinit(allocator);
    }
    try gltf_document.appendExternalDependencies(allocator, &gltf.value, source.path, &dep_paths);

    const deps = try allocator.alloc(SourceFile, dep_paths.items.len);
    errdefer allocator.free(deps);

    for (dep_paths.items, 0..) |path, i| {
        deps[i] = SourceFile.fromPath(path);
    }
    dep_paths.deinit(allocator);

    return deps;
}

const testing = std.testing;

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

test "extractMeshDeps returns external gltf buffer and image dependencies" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "meshes/quad");
    try writeFile(tmp.dir, "meshes/quad/textured_quad.gltf",
        \\{
        \\  "buffers":[{"byteLength":4,"uri":"textured_quad.bin"}],
        \\  "images":[{"uri":"textured_quad_albedo.png"}]
        \\}
    );

    const sf = SourceFile{ .path = "meshes/quad/textured_quad.gltf", .extension = .gltf, .assetType = .mesh };
    const deps = try extractMeshDeps(&sf, tmp.dir, testing.io, testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d.path);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("meshes/quad/textured_quad.bin", deps[0].path);
    try testing.expectEqual(.bin, deps[0].extension);
    try testing.expectEqual(.unknown, deps[0].assetType);
    try testing.expectEqualStrings("meshes/quad/textured_quad_albedo.png", deps[1].path);
    try testing.expectEqual(.png, deps[1].extension);
    try testing.expectEqual(.texture, deps[1].assetType);
}

test "extractMeshDeps returns empty dependencies for embedded glb" {
    const sf = SourceFile{ .path = "meshes/triangle.glb", .extension = .glb, .assetType = .mesh };
    const deps = try extractMeshDeps(&sf, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}
