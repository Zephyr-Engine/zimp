const std = @import("std");

const DependencyExtractor = @import("extractor.zig").DependencyExtractor;
const SourceFile = @import("../assets/source_file.zig").SourceFile;

pub fn extractor() DependencyExtractor {
    return .{ .extractFn = extractShaderDeps, .asset_type = .shader };
}

fn extractShaderDeps(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    const file = try dir.openFile(io, source.path, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buffer);
    var reader = &fr.interface;

    var deps: std.ArrayList(SourceFile) = .empty;
    errdefer {
        for (deps.items) |d| allocator.free(d.path);
        deps.deinit(allocator);
    }

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (parseIncludeFilename(line)) |filename| {
            const path = try allocator.dupe(u8, filename);
            errdefer allocator.free(path);
            try deps.append(allocator, SourceFile.fromPath(path));
        }
    }

    return deps.toOwnedSlice(allocator);
}

fn parseIncludeFilename(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) {
        return null;
    }
    if (!std.mem.startsWith(u8, trimmed, "#include")) {
        return null;
    }

    const after_directive = std.mem.trim(u8, trimmed["#include".len..], " \t");
    if (after_directive.len < 2) {
        return null;
    }

    const close_char: u8 = switch (after_directive[0]) {
        '"' => '"',
        '<' => '>',
        else => return null,
    };

    const rest = after_directive[1..];
    const end = std.mem.indexOfScalar(u8, rest, close_char) orelse return null;
    if (end == 0) {
        return null;
    }

    return rest[0..end];
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
