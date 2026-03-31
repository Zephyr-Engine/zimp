const std = @import("std");

const logger = @import("logger.zig").logger;
const asset = @import("asset.zig");

pub const SourceFile = struct {
    path: []const u8,
    extension: asset.Extension,
    assetType: asset.AssetType,
};

pub const SourceFileList = std.ArrayList(SourceFile);

pub const AssetScanner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    root_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, root_name: []const u8) AssetScanner {
        return .{
            .io = io,
            .dir = dir,
            .allocator = allocator,
            .root_name = root_name,
        };
    }

    pub fn scan(self: AssetScanner) !SourceFileList {
        var files: std.ArrayList(SourceFile) = .empty;
        try self.scanDir(self.dir, self.root_name, &files);
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
                logger.info("Found {s} file: {s}", .{ ext.string(), path });
            } else if (entry.kind == .directory) {
                const subdir = try std.Io.Dir.openDir(dir, self.io, entry.name, .{ .iterate = true });
                const subprefix = if (prefix.len > 0)
                    try std.fs.path.join(self.allocator, &.{ prefix, entry.name })
                else
                    entry.name;

                defer if (prefix.len > 0) self.allocator.free(subprefix);
                try self.scanDir(subdir, subprefix, files);
            }
        }
    }

    fn logResults(files: SourceFileList) void {
        var counts = std.EnumArray(asset.AssetType, usize).initFill(0);
        for (files.items) |file| {
            counts.getPtr(file.assetType).* += 1;
        }

        logger.info("\x1b[32m---------------------------------------------\x1b[0m", .{});
        logger.info("\x1b[32m|                 SUMMARY                   |\x1b[0m", .{});
        logger.info("\x1b[32m---------------------------------------------\x1b[0m", .{});
        logger.info("Found {d} assets", .{files.items.len});

        for (std.enums.values(asset.AssetType)) |asset_type| {
            if (asset_type == .unknown) continue;
            const count = counts.get(asset_type);
            if (count > 0) {
                logger.info("  {s}: {d}", .{ @tagName(asset_type), count });
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

fn testScanner(root_name: []const u8) AssetScanner {
    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, testing.io, "examples/assets", .{ .iterate = true }) catch unreachable;
    return AssetScanner.init(testing.allocator, testing.io, dir, root_name);
}

fn containsPath(files: SourceFileList, path: []const u8) bool {
    for (files.items) |file| {
        if (std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}

test "AssetScanner.scan finds gltf files" {
    const scanner = testScanner("assets");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    try testing.expect(containsPath(list, "assets/meshes/triangle.glb"));
}

test "AssetScanner.scan assigns correct extension" {
    const scanner = testScanner("assets");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        if (std.mem.eql(u8, file.path, "assets/meshes/triangle.glb")) {
            try testing.expectEqual(.glb, file.extension);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "AssetScanner.scan assigns correct asset type" {
    const scanner = testScanner("assets");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        if (std.mem.eql(u8, file.path, "assets/meshes/triangle.glb")) {
            try testing.expectEqual(.mesh, file.assetType);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "AssetScanner.scan skips non-matching extensions" {
    const scanner = testScanner("assets");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        try testing.expect(file.extension != .other);
    }
}

test "AssetScanner.scan uses root_name as path prefix" {
    const scanner = testScanner("my_root");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        try testing.expect(std.mem.startsWith(u8, file.path, "my_root/"));
    }
}

test "AssetScanner.scan with empty root_name produces bare filenames" {
    const scanner = testScanner("");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    try testing.expect(containsPath(list, "meshes/triangle.glb"));
}

test "AssetScanner.deinit frees all memory" {
    const scanner = testScanner("assets");
    var list = try scanner.scan();
    scanner.deinit(&list);
}

test "AssetScanner.scan returns empty list for directory with no matching files" {
    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, testing.io, "examples/output", .{ .iterate = true }) catch unreachable;
    const scanner = AssetScanner.init(testing.allocator, testing.io, dir, "nested");
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    for (list.items) |file| {
        try testing.expect(file.extension != .other);
    }
}
