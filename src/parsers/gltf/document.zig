const std = @import("std");

const file_read = @import("../../shared/file_read.zig");
const Gltf = @import("gltf_json_parser.zig").Gltf;
const GltfJson = @import("gltf_json_parser.zig").GltfJson;

pub const GltfUriError = error{
    EmptyUri,
    InvalidUriEscape,
    OutOfMemory,
    UnsupportedUri,
    UnsafeUri,
};

pub const GltfDocument = struct {
    allocator: std.mem.Allocator,
    json_bytes: []u8,
    gltf: Gltf,
    buffers: [][]const u8,

    pub fn loadGltf(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        file_path: []const u8,
    ) !GltfDocument {
        const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path, .{
            .chunk_size = 256 * 1024,
        });
        errdefer allocator.free(file_result.bytes);

        var gltf = try Gltf.parse(file_result.bytes, allocator);
        errdefer gltf.deinit();

        const buffers = try allocator.alloc([]const u8, gltf.value.buffers.len);
        errdefer allocator.free(buffers);

        var loaded_count: usize = 0;
        errdefer {
            for (buffers[0..loaded_count]) |bytes| allocator.free(bytes);
        }

        for (gltf.value.buffers, 0..) |buffer, i| {
            const uri = buffer.uri orelse return GltfUriError.UnsupportedUri;
            const path = try resolveRelativeUri(allocator, file_path, uri);
            defer allocator.free(path);

            const buffer_result = try file_read.readFileAllocChunked(allocator, io, source_dir, path, .{
                .chunk_size = 256 * 1024,
            });
            errdefer allocator.free(buffer_result.bytes);

            if (buffer_result.bytes.len < buffer.byteLength) {
                return error.UnexpectedEndOfStream;
            }

            buffers[i] = buffer_result.bytes;
            loaded_count += 1;
        }

        return .{
            .allocator = allocator,
            .json_bytes = file_result.bytes,
            .gltf = gltf,
            .buffers = buffers,
        };
    }

    pub fn deinit(self: *GltfDocument) void {
        for (self.buffers) |bytes| {
            self.allocator.free(bytes);
        }
        self.allocator.free(self.buffers);
        self.gltf.deinit();
        self.allocator.free(self.json_bytes);
        self.* = undefined;
    }
};

pub fn appendExternalDependencies(
    allocator: std.mem.Allocator,
    gltf: *const GltfJson,
    source_path: []const u8,
    deps: *std.ArrayList([]u8),
) !void {
    for (gltf.buffers) |buffer| {
        if (buffer.uri) |uri| {
            try deps.append(allocator, try resolveRelativeUri(allocator, source_path, uri));
        }
    }

    for (gltf.images) |image| {
        if (image.uri) |uri| {
            try deps.append(allocator, try resolveRelativeUri(allocator, source_path, uri));
        }
    }
}

pub fn resolveRelativeUri(allocator: std.mem.Allocator, source_path: []const u8, uri: []const u8) GltfUriError![]u8 {
    if (uri.len == 0) return GltfUriError.EmptyUri;
    if (hasUriScheme(uri) or std.mem.startsWith(u8, uri, "//")) {
        return GltfUriError.UnsupportedUri;
    }
    if (std.mem.indexOfAny(u8, uri, "?#") != null) {
        return GltfUriError.UnsupportedUri;
    }

    const decoded = try percentDecode(allocator, uri);
    defer allocator.free(decoded);

    if (std.mem.indexOfScalar(u8, decoded, '\\') != null or std.fs.path.isAbsolute(decoded)) {
        return GltfUriError.UnsafeUri;
    }

    const joined = if (std.fs.path.dirname(source_path)) |dir|
        try std.fs.path.join(allocator, &.{ dir, decoded })
    else
        try allocator.dupe(u8, decoded);
    defer allocator.free(joined);

    return normalizeRelativePath(allocator, joined);
}

fn hasUriScheme(uri: []const u8) bool {
    if (uri.len == 0 or !std.ascii.isAlphabetic(uri[0])) return false;
    for (uri[1..]) |c| {
        switch (c) {
            ':' => return true,
            '/', '?', '#' => return false,
            'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => {},
            else => return false,
        }
    }
    return false;
}

fn percentDecode(allocator: std.mem.Allocator, uri: []const u8) GltfUriError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < uri.len) {
        if (uri[i] != '%') {
            try out.append(allocator, uri[i]);
            i += 1;
            continue;
        }

        if (i + 2 >= uri.len) {
            return GltfUriError.InvalidUriEscape;
        }
        const hi = std.fmt.charToDigit(uri[i + 1], 16) catch return GltfUriError.InvalidUriEscape;
        const lo = std.fmt.charToDigit(uri[i + 2], 16) catch return GltfUriError.InvalidUriEscape;
        try out.append(allocator, @intCast(hi * 16 + lo));
        i += 3;
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeRelativePath(allocator: std.mem.Allocator, path: []const u8) GltfUriError![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) {
            continue;
        }
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) {
                return GltfUriError.UnsafeUri;
            }
            parts.items.len -= 1;
            continue;
        }
        try parts.append(allocator, part);
    }

    return std.mem.join(allocator, "/", parts.items);
}

const testing = std.testing;

test "resolveRelativeUri resolves nested file relative to gltf" {
    const path = try resolveRelativeUri(testing.allocator, "meshes/gltf/model.gltf", "buffers/model.bin");
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("meshes/gltf/buffers/model.bin", path);
}

test "resolveRelativeUri percent decodes simple escapes" {
    const path = try resolveRelativeUri(testing.allocator, "meshes/model.gltf", "texture%20albedo.png");
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("meshes/texture albedo.png", path);
}

test "resolveRelativeUri allows parent paths that stay under source root" {
    const path = try resolveRelativeUri(testing.allocator, "meshes/nested/model.gltf", "../shared/buffer.bin");
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("meshes/shared/buffer.bin", path);
}

test "resolveRelativeUri rejects parent traversal outside source root" {
    try testing.expectError(GltfUriError.UnsafeUri, resolveRelativeUri(testing.allocator, "model.gltf", "../outside.bin"));
}

test "resolveRelativeUri rejects absolute and remote uri forms" {
    try testing.expectError(GltfUriError.UnsafeUri, resolveRelativeUri(testing.allocator, "model.gltf", "/tmp/a.bin"));
    try testing.expectError(GltfUriError.UnsupportedUri, resolveRelativeUri(testing.allocator, "model.gltf", "https://example.com/a.bin"));
    try testing.expectError(GltfUriError.UnsupportedUri, resolveRelativeUri(testing.allocator, "model.gltf", "data:application/octet-stream;base64,AA=="));
}

test "appendExternalDependencies returns buffers and images" {
    var buffers = [_]@import("gltf_json_parser.zig").GltfBuffer{
        .{ .byteLength = 1, .uri = "mesh.bin" },
    };
    var images = [_]@import("gltf_json_parser.zig").GltfImage{
        .{ .uri = "albedo.png" },
    };
    const gltf = GltfJson{
        .buffers = &buffers,
        .images = &images,
    };

    var deps: std.ArrayList([]u8) = .empty;
    defer {
        for (deps.items) |path| testing.allocator.free(path);
        deps.deinit(testing.allocator);
    }

    try appendExternalDependencies(testing.allocator, &gltf, "meshes/quad/model.gltf", &deps);

    try testing.expectEqual(@as(usize, 2), deps.items.len);
    try testing.expectEqualStrings("meshes/quad/mesh.bin", deps.items[0]);
    try testing.expectEqualStrings("meshes/quad/albedo.png", deps.items[1]);
}
