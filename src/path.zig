const std = @import("std");

const AssetType = @import("assets/asset.zig").AssetType;

pub const Error = error{
    AbsolutePathNotAllowed,
    ParentTraversalNotAllowed,
    EmptyPath,
    PathTooLong,
    OutOfMemory,
};

pub const max_virtual_path_len: usize = 4096;

pub fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) {
        return false;
    }
    if (isSeparator(path[0])) {
        return true;
    }
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

pub fn normalizeVirtual(allocator: std.mem.Allocator, raw_path: []const u8) Error![]u8 {
    if (raw_path.len == 0) {
        return Error.EmptyPath;
    }
    if (raw_path.len > max_virtual_path_len) {
        return Error.PathTooLong;
    }
    if (isAbsolute(raw_path)) {
        return Error.AbsolutePathNotAllowed;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw_path.len) {
        while (i < raw_path.len and isSeparator(raw_path[i])) : (i += 1) {}
        const start = i;
        while (i < raw_path.len and !isSeparator(raw_path[i])) : (i += 1) {}
        const segment = raw_path[start..i];

        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            continue;
        }
        if (std.mem.eql(u8, segment, "..")) {
            return Error.ParentTraversalNotAllowed;
        }

        if (out.items.len != 0) {
            try out.append(allocator, '/');
        }
        try out.appendSlice(allocator, segment);
    }

    if (out.items.len == 0) {
        return Error.EmptyPath;
    }
    if (out.items.len > max_virtual_path_len) {
        return Error.PathTooLong;
    }

    return out.toOwnedSlice(allocator);
}

pub fn validateVirtual(path: []const u8) Error!void {
    if (path.len == 0) {
        return Error.EmptyPath;
    }
    if (path.len > max_virtual_path_len) {
        return Error.PathTooLong;
    }
    if (isAbsolute(path)) {
        return Error.AbsolutePathNotAllowed;
    }

    var saw_segment = false;
    var i: usize = 0;
    while (i < path.len) {
        while (i < path.len and isSeparator(path[i])) : (i += 1) {}
        const start = i;
        while (i < path.len and !isSeparator(path[i])) : (i += 1) {}
        const segment = path[start..i];
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            continue;
        }
        if (std.mem.eql(u8, segment, "..")) {
            return Error.ParentTraversalNotAllowed;
        }
        saw_segment = true;
    }

    if (!saw_segment) {
        return Error.EmptyPath;
    }
}

pub fn resolveRelativeVirtual(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    dependency_path: []const u8,
) Error![]u8 {
    try validateVirtual(base_path);
    if (dependency_path.len == 0) return Error.EmptyPath;
    if (isAbsolute(dependency_path)) return Error.AbsolutePathNotAllowed;

    const slash_index = std.mem.lastIndexOfScalar(u8, base_path, '/');
    if (slash_index == null) {
        return normalizeVirtual(allocator, dependency_path);
    }

    const base_dir = base_path[0..slash_index.?];
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, dependency_path });
    defer allocator.free(joined);

    return normalizeVirtual(allocator, joined);
}

pub fn normalizeRelative(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(allocator);

    var i: usize = 0;
    while (i < raw_path.len) {
        while (i < raw_path.len and isSeparator(raw_path[i])) : (i += 1) {}
        const start = i;
        while (i < raw_path.len and !isSeparator(raw_path[i])) : (i += 1) {}
        const part = raw_path[start..i];

        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
        } else if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try parts.append(allocator, part);
        }
    }

    return std.mem.join(allocator, "/", parts.items);
}

pub fn resolveShaderInclude(
    allocator: std.mem.Allocator,
    shader_path: []const u8,
    include: []const u8,
) ![]u8 {
    const dir = std.fs.path.dirname(shader_path) orelse return normalizeRelative(allocator, include);
    const joined = try std.fs.path.join(allocator, &.{ dir, include });
    defer allocator.free(joined);
    return normalizeRelative(allocator, joined);
}

pub fn cookedOutput(allocator: std.mem.Allocator, file_path: []const u8, asset_type: AssetType) ![]u8 {
    const name = if (asset_type == .shader)
        std.fs.path.basename(file_path)
    else
        std.fs.path.stem(file_path);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{
        name,
        asset_type.cookedExtension(),
    });
}

const testing = std.testing;

fn expectNormalizedVirtual(input: []const u8, expected: []const u8) !void {
    const normalized = try normalizeVirtual(testing.allocator, input);
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings(expected, normalized);
}

test "normalizeVirtual normalizes separators and leading dot segments" {
    try expectNormalizedVirtual("meshes\\monkey.zmesh", "meshes/monkey.zmesh");
    try expectNormalizedVirtual("./monkey.zmesh", "monkey.zmesh");
    try expectNormalizedVirtual("meshes///monkey.zmesh", "meshes/monkey.zmesh");
}

test "normalizeVirtual rejects unsafe paths" {
    try testing.expectError(Error.ParentTraversalNotAllowed, normalizeVirtual(testing.allocator, "../secret.zmesh"));
    try testing.expectError(Error.ParentTraversalNotAllowed, normalizeVirtual(testing.allocator, "materials/../secret.zmesh"));
    try testing.expectError(Error.AbsolutePathNotAllowed, normalizeVirtual(testing.allocator, "/tmp/file.zmesh"));
    try testing.expectError(Error.AbsolutePathNotAllowed, normalizeVirtual(testing.allocator, "C:\\tmp\\file.zmesh"));
}

test "resolveRelativeVirtual joins sibling dependencies" {
    const resolved = try resolveRelativeVirtual(testing.allocator, "materials/monkey.zamat", "brick_albedo.ztex");
    defer testing.allocator.free(resolved);
    try testing.expectEqualStrings("materials/brick_albedo.ztex", resolved);
}

test "resolveRelativeVirtual rejects parent traversal" {
    try testing.expectError(
        Error.ParentTraversalNotAllowed,
        resolveRelativeVirtual(testing.allocator, "materials/monkey.zamat", "../x.ztex"),
    );
}

test "normalizeRelative resolves path components" {
    const p = try normalizeRelative(testing.allocator, "shaders/../shared/./lighting.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shared/lighting.glsl", p);
}

test "resolveShaderInclude prefixes include with shader directory" {
    const p = try resolveShaderInclude(testing.allocator, "shaders/basic.frag", "common.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shaders/common.glsl", p);
}

test "resolveShaderInclude resolves parent directory traversal" {
    const p = try resolveShaderInclude(testing.allocator, "shaders/basic.frag", "../shared/lighting.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("shared/lighting.glsl", p);
}

test "resolveShaderInclude returns normalized include when shader has no directory" {
    const p = try resolveShaderInclude(testing.allocator, "basic.frag", "./common.glsl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("common.glsl", p);
}

test "cooked output paths use standardized naming" {
    const shader = try cookedOutput(testing.allocator, "shaders/basic.vert", .shader);
    defer testing.allocator.free(shader);
    try testing.expectEqualStrings("basic.vert.zshdr", shader);

    const mesh = try cookedOutput(testing.allocator, "meshes/triangle.glb", .mesh);
    defer testing.allocator.free(mesh);
    try testing.expectEqualStrings("triangle.zmesh", mesh);

    const texture = try cookedOutput(testing.allocator, "textures/test_albedo.png", .texture);
    defer testing.allocator.free(texture);
    try testing.expectEqualStrings("test_albedo.ztex", texture);
}
