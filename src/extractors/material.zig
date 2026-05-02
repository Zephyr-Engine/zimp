const std = @import("std");

const DependencyExtractor = @import("extractor.zig").DependencyExtractor;
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const raw_material = @import("../assets/raw/material.zig");
const file_read = @import("../shared/file_read.zig");

pub fn extractor() DependencyExtractor {
    return .{ .extractFn = extractMaterialDeps, .asset_type = .material };
}

fn extractMaterialDeps(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    const file_result = try file_read.readFileAllocChunked(allocator, io, dir, source.path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    var material = try raw_material.parseMaterialSource(file_result.bytes, allocator);
    defer material.deinit(allocator);

    var deps: std.ArrayList(SourceFile) = .empty;
    errdefer {
        for (deps.items) |d| allocator.free(d.path);
        deps.deinit(allocator);
    }

    const vert_path = try std.fmt.allocPrint(allocator, "{s}.vert", .{material.shader_path});
    errdefer allocator.free(vert_path);
    try deps.append(allocator, SourceFile.fromPath(vert_path));

    const frag_path = try std.fmt.allocPrint(allocator, "{s}.frag", .{material.shader_path});
    errdefer allocator.free(frag_path);
    try deps.append(allocator, SourceFile.fromPath(frag_path));

    for (material.textures) |slot| {
        const path = try allocator.dupe(u8, slot.texture_path);
        errdefer allocator.free(path);
        try deps.append(allocator, SourceFile.fromPath(path));
    }

    return deps.toOwnedSlice(allocator);
}

const testing = std.testing;

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dirname| {
        try dir.createDirPath(testing.io, dirname);
    }
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

test "extractMaterialDeps returns shader stages and textures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[textures]
        \\albedo = "textures/test_albedo.png"
        \\normal = "textures/test_normal.png"
        \\
    );

    const sf = SourceFile.fromPath("materials/test.zamat");
    const deps = try extractMaterialDeps(&sf, tmp.dir, testing.io, testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d.path);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 4), deps.len);
    try testing.expectEqualStrings("shaders/basic.vert", deps[0].path);
    try testing.expectEqualStrings("shaders/basic.frag", deps[1].path);
    try testing.expectEqualStrings("textures/test_albedo.png", deps[2].path);
    try testing.expectEqualStrings("textures/test_normal.png", deps[3].path);
}
