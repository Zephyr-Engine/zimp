const std = @import("std");

const SourceFile = @import("source_file.zig").SourceFile;
const log = @import("../logger.zig");
const asset = @import("asset.zig");
const meta_mod = @import("../manifest/meta.zig");

pub const SourceFileList = std.ArrayList(SourceFile);

pub const ScanResult = struct {
    files: SourceFileList = .empty,
    orphan_sidecars: std.ArrayList([]u8) = .empty,
};

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
        var result = try self.scanDetailed();
        for (result.orphan_sidecars.items) |path| {
            self.allocator.free(path);
        }

        result.orphan_sidecars.deinit(self.allocator);
        return result.files;
    }

    pub fn scanDetailed(self: AssetScanner) !ScanResult {
        var result: ScanResult = .{};
        errdefer self.deinitDetailed(&result);

        try self.scanDir(self.dir, "", &result.files, &result.orphan_sidecars);
        logResults(result.files);

        return result;
    }

    fn scanDir(self: AssetScanner, dir: std.Io.Dir, prefix: []const u8, files: *SourceFileList, orphan_sidecars: *std.ArrayList([]u8)) !void {
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind == .file) {
                if (meta_mod.isMetaPath(entry.name)) {
                    const source_name = entry.name[0 .. entry.name.len - meta_mod.meta_extension.len];
                    dir.access(self.io, source_name, .{}) catch {
                        try orphan_sidecars.append(self.allocator, try self.joinPath(prefix, entry.name));
                    };
                    continue;
                }
                const ext = asset.Extension.processEntry(entry);
                if (ext == .other) {
                    continue;
                }

                const path = try self.joinPath(prefix, entry.name);

                try files.append(self.allocator, .{
                    .extension = ext,
                    .path = path,
                });
            } else if (entry.kind == .directory) {
                const subdir = try std.Io.Dir.openDir(dir, self.io, entry.name, .{ .iterate = true });
                defer subdir.close(self.io);
                const subprefix = try self.joinPath(prefix, entry.name);
                defer self.allocator.free(subprefix);
                try self.scanDir(subdir, subprefix, files, orphan_sidecars);
            }
        }
    }

    fn logResults(files: SourceFileList) void {
        var counts = std.EnumArray(asset.AssetKind, usize).initFill(0);
        for (files.items) |file| {
            const kind = file.assetKind() orelse continue;
            counts.getPtr(kind).* += 1;
        }

        log.debug("Found {d} assets", .{files.items.len});

        for (std.enums.values(asset.AssetKind)) |kind| {
            const count = counts.get(kind);
            if (count > 0) {
                log.debug("  {s}: {d}", .{ @tagName(kind), count });
            }
        }
    }

    pub fn deinit(self: AssetScanner, list: *SourceFileList) void {
        for (list.items) |file| {
            self.allocator.free(file.path);
        }
        list.deinit(self.allocator);
    }

    pub fn deinitDetailed(self: AssetScanner, result: *ScanResult) void {
        self.deinit(&result.files);
        for (result.orphan_sidecars.items) |path| {
            self.allocator.free(path);
        }
        result.orphan_sidecars.deinit(self.allocator);
    }

    fn joinPath(self: AssetScanner, prefix: []const u8, name: []const u8) ![]u8 {
        if (prefix.len == 0) {
            return self.allocator.dupe(u8, name);
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name });
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
            try testing.expectEqual(.mesh, file.assetKind());
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
            std.mem.startsWith(u8, file.path, "materials/") or
            std.mem.startsWith(u8, file.path, "generated/");
        try testing.expect(valid);
    }
}

test "AssetScanner.deinit frees all memory" {
    const scanner = testScanner();
    var list = try scanner.scan();
    scanner.deinit(&list);
}

test "AssetScanner.scan returns empty list for directory with no matching files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std.Io.Dir.openDir(tmp.dir, testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    const scanner = AssetScanner.init(testing.allocator, testing.io, dir);
    var list = try scanner.scan();
    defer scanner.deinit(&list);

    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "AssetScanner.scanDetailed reports orphan sidecars" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "missing.glb.zmeta", .data = "{}" });
    const dir = try std.Io.Dir.openDir(tmp.dir, testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    const scanner = AssetScanner.init(testing.allocator, testing.io, dir);
    var result = try scanner.scanDetailed();
    defer scanner.deinitDetailed(&result);

    try testing.expectEqual(@as(usize, 1), result.orphan_sidecars.items.len);
    try testing.expectEqualStrings("missing.glb.zmeta", result.orphan_sidecars.items[0]);
}
