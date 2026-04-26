const std = @import("std");

const DependencyExtractor = @import("extractor.zig").DependencyExtractor;
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const shader_source = @import("../assets/raw/shader.zig");
const file_read = @import("../shared/file_read.zig");

const parseIncludeFilename = shader_source.parseIncludeFilename;
const resolveIncludePath = shader_source.resolveIncludePath;
const normalizePath = shader_source.normalizePath;

pub fn extractor() DependencyExtractor {
    return .{ .extractFn = extractShaderDeps, .asset_type = .shader };
}

fn extractShaderDeps(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    const file_result = try file_read.readFileAllocChunked(allocator, io, dir, source.path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    var deps: std.ArrayList(SourceFile) = .empty;
    errdefer {
        for (deps.items) |d| allocator.free(d.path);
        deps.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, file_result.bytes, '\n');
    while (lines.next()) |line| {
        if (parseIncludeFilename(line)) |filename| {
            const path = try resolveIncludePath(allocator, source.path, filename);
            errdefer allocator.free(path);
            try deps.append(allocator, SourceFile.fromPath(path));
        }
    }

    return deps.toOwnedSlice(allocator);
}

const testing = std.testing;

test "parseIncludeFilename matches quoted include" {
    try testing.expectEqualStrings("foo.glsl", parseIncludeFilename("#include \"foo.glsl\"\n").?);
}

test "parseIncludeFilename matches angle-bracket include" {
    try testing.expectEqualStrings("bar.glsl", parseIncludeFilename("#include <bar.glsl>\n").?);
}

test "parseIncludeFilename allows leading whitespace" {
    try testing.expectEqualStrings("baz.glsl", parseIncludeFilename("    #include \"baz.glsl\"\n").?);
}

test "parseIncludeFilename allows tab indentation" {
    try testing.expectEqualStrings("tab.glsl", parseIncludeFilename("\t#include \"tab.glsl\"\n").?);
}

test "parseIncludeFilename allows extra whitespace after directive" {
    try testing.expectEqualStrings("spaces.glsl", parseIncludeFilename("#include    \"spaces.glsl\"\n").?);
}

test "parseIncludeFilename ignores // commented-out include" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("// #include \"skip.glsl\"\n"));
}

test "parseIncludeFilename ignores // with leading whitespace" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("   // #include \"skip.glsl\"\n"));
}

test "parseIncludeFilename ignores non-include lines" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("void main() {}\n"));
}

test "parseIncludeFilename ignores unclosed quote" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("#include \"unclosed\n"));
}

test "parseIncludeFilename ignores empty filename" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("#include \"\"\n"));
}

test "parseIncludeFilename ignores mismatched delimiters" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("#include \"foo>\n"));
}

test "parseIncludeFilename ignores line without whitespace or bracket after directive" {
    try testing.expectEqual(@as(?[]const u8, null), parseIncludeFilename("#includefoo\n"));
}

test "normalizePath leaves simple path unchanged" {
    const p = try normalizePath(testing.allocator, "shaders/common.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shaders/common.glsl", p);
}

test "normalizePath resolves double-dot" {
    const p = try normalizePath(testing.allocator, "shaders/../shared/lighting.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shared/lighting.glsl", p);
}

test "normalizePath resolves dot component" {
    const p = try normalizePath(testing.allocator, "shaders/./common.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shaders/common.glsl", p);
}

test "resolveIncludePath prefixes include with shader directory" {
    const p = try resolveIncludePath(testing.allocator, "shaders/basic.frag", "common.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shaders/common.glsl", p);
}

test "resolveIncludePath resolves parent directory traversal" {
    const p = try resolveIncludePath(testing.allocator, "shaders/basic.frag", "../shared/lighting.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shared/lighting.glsl", p);
}

test "resolveIncludePath returns include as-is when shader has no directory" {
    const p = try resolveIncludePath(testing.allocator, "basic.frag", "common.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("common.glsl", p);
}

test "extractShaderDeps returns #include paths from a shader file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "basic.frag", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(
        \\#version 330 core
        \\#include "common.glsl"
        \\// #include "ignored.glsl"
        \\#include <angle.glsl>
        \\void main() {}
        \\
    );
    try writer.interface.flush();
    file.close(testing.io);

    const sf = SourceFile{ .path = "basic.frag", .extension = .frag, .assetType = .shader };
    const deps = try extractShaderDeps(&sf, tmp.dir, testing.io, testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d.path);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("common.glsl", deps[0].path);
    try testing.expectEqual(.glsl, deps[0].extension);
    try testing.expectEqual(.shader, deps[0].assetType);
    try testing.expectEqualStrings("angle.glsl", deps[1].path);
    try testing.expectEqual(.glsl, deps[1].extension);
    try testing.expectEqual(.shader, deps[1].assetType);
}

test "extractShaderDeps resolves includes relative to shader directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "shaders");
    const file = try tmp.dir.createFile(testing.io, "shaders/basic.frag", .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(
        \\#include "common.glsl"
        \\#include "../shared/lighting.glsl"
        \\
    );
    try writer.interface.flush();
    file.close(testing.io);

    const sf = SourceFile{ .path = "shaders/basic.frag", .extension = .frag, .assetType = .shader };
    const deps = try extractShaderDeps(&sf, tmp.dir, testing.io, testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d.path);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("shaders/common.glsl", deps[0].path);
    try testing.expectEqualStrings("shared/lighting.glsl", deps[1].path);
}
