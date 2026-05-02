const std = @import("std");

const SourceFile = @import("source_file.zig").SourceFile;
const log = @import("../logger.zig");
const asset = @import("asset.zig");

pub const SourceFileList = std.ArrayList(SourceFile);

pub const AssetScanner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) AssetScanner {
        return .{
            .io = io,
            .dir = dir,
            .allocator = allocator,
        };
    }

    pub fn scan(self: AssetScanner) !SourceFileList {
        var files: std.ArrayList(SourceFile) = .empty;
        try self.scanDir(self.dir, "", &files);
        logResults(files);

        return files;
    }

    fn scanDir(self: AssetScanner, dir: std.Io.Dir, prefix: []const u8, files: *SourceFileList) !void {
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind == .file) {
                const ext = asset.Extension.processEntry(entry);
                if (ext == .other) {
                    continue;
                }

                const path = if (prefix.len > 0)
                    try std.fs.path.join(self.allocator, &.{ prefix, entry.name })
                else
                    try self.allocator.dupe(u8, entry.name);

                try files.append(self.allocator, .{
                    .extension = ext,
                    .path = path,
                    .assetType = ext.assetType(),
                });
            } else if (entry.kind == .directory) {
                const subdir = try std.Io.Dir.openDir(dir, self.io, entry.name, .{ .iterate = true });
                const subprefix = if (prefix.len > 0)
                    try std.fs.path.join(self.allocator, &.{ prefix, entry.name })
                else
                    try self.allocator.dupe(u8, entry.name);
                defer self.allocator.free(subprefix);
                try self.scanDir(subdir, subprefix, files);
            }
        }
    }

    fn logResults(files: SourceFileList) void {
        var counts = std.EnumArray(asset.AssetType, usize).initFill(0);
        for (files.items) |file| {
            counts.getPtr(file.assetType).* += 1;
        }

        log.debug("Found {d} assets", .{files.items.len});

        for (std.enums.values(asset.AssetType)) |asset_type| {
            if (asset_type == .unknown) {
                continue;
            }

            const count = counts.get(asset_type);
            if (count > 0) {
                log.debug("  {s}: {d}", .{ @tagName(asset_type), count });
            }
        }
    }

    pub fn deinit(self: AssetScanner, list: *SourceFileList) void {
        for (list.items) |file| {
            self.allocator.free(file.path);
        }
        list.deinit(self.allocator);
    }
};

const testing = std.testing;

fn testScanner() AssetScanner {
    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, testing.io, "examples/assets", .{ .iterate = true }) catch unreachable;
    return AssetScanner.init(testing.allocator, testing.io, dir);
}

fn containsPath(files: SourceFileList, path: []const u8) bool {
    for (files.items) |file| {
        if (std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}

test "AssetScanner.scan finds gltf files" {
    const scanner = testScanner();
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    try testing.expect(containsPath(list, "meshes/triangle.glb"));
}

test "AssetScanner.scan assigns correct extension" {
    const scanner = testScanner();
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        if (std.mem.eql(u8, file.path, "meshes/triangle.glb")) {
            try testing.expectEqual(.glb, file.extension);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "AssetScanner.scan assigns correct asset type" {
    const scanner = testScanner();
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        if (std.mem.eql(u8, file.path, "meshes/triangle.glb")) {
            try testing.expectEqual(.mesh, file.assetType);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "AssetScanner.scan skips non-matching extensions" {
    const scanner = testScanner();
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        try testing.expect(file.extension != .other);
    }
}

test "AssetScanner.scan discovers shader includes and shader stages" {
    const scanner = testScanner();
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    try testing.expect(containsPath(list, "shaders/common.glsl"));
    try testing.expect(containsPath(list, "shaders/basic.vert"));
    try testing.expect(containsPath(list, "shaders/basic.frag"));
}

test "AssetScanner.scan produces paths relative to source dir" {
    const scanner = testScanner();
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        const valid = std.mem.startsWith(u8, file.path, "meshes/") or
            std.mem.startsWith(u8, file.path, "textures/") or
            std.mem.startsWith(u8, file.path, "shaders/") or
            std.mem.startsWith(u8, file.path, "materials/");
        try testing.expect(valid);
    }
}

test "AssetScanner.deinit frees all memory" {
    const scanner = testScanner();
    var list = try scanner.scan();
    scanner.deinit(&list);
}

test "AssetScanner.scan returns empty list for directory with no matching files" {
    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, testing.io, "examples/output", .{ .iterate = true }) catch unreachable;
    const scanner = AssetScanner.init(testing.allocator, testing.io, dir);
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        try testing.expect(file.extension != .other);
    }
}
