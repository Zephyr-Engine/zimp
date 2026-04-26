const std = @import("std");

const asset = @import("asset.zig");

pub const Hash = u64;

const FNV_PRIME: Hash = 0x00000100000001B3;
const FNV_OFFSET_BASIS: Hash = 0xcbf29ce484222325;

pub fn fnv1a(path: []const u8) Hash {
    var hash: Hash = FNV_OFFSET_BASIS;
    for (path) |byte| {
        const b: u8 = if (byte == '\\') '/' else byte;
        hash ^= b;
        hash *%= FNV_PRIME;
    }
    return hash;
}

pub const SourceFile = struct {
    path: []const u8,
    extension: asset.Extension,
    assetType: asset.AssetType,

    pub fn fromPath(path: []const u8) SourceFile {
        const ext = asset.Extension.fromName(std.fs.path.basename(path));
        return .{
            .path = path,
            .extension = ext,
            .assetType = ext.assetType(),
        };
    }

    pub const FileInfo = struct {
        size: u64,
        modified_ns: i96,
    };

    pub fn getFileInfo(self: *const SourceFile, dir: std.Io.Dir, io: std.Io) !FileInfo {
        const file = try dir.openFile(io, self.path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        return .{
            .size = stat.size,
            .modified_ns = stat.mtime.nanoseconds,
        };
    }

    pub fn hash(self: *const SourceFile, dir: std.Io.Dir, io: std.Io) !Hash {
        const file = try dir.openFile(io, self.path, .{});
        defer file.close(io);

        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        var reader = &fr.interface;

        var hr = reader.hashed(std.hash.XxHash64.init(0), &buf);
        _ = try hr.reader.discardRemaining();

        return hr.hasher.final();
    }

    pub fn hashPath(self: *const SourceFile) Hash {
        return fnv1a(self.path);
    }

    pub const CookedFile = struct {
        file: std.Io.File,
        path: []u8,
    };

    pub fn createCookedFile(self: *const SourceFile, allocator: std.mem.Allocator, io: std.Io, output_dir: std.Io.Dir) !CookedFile {
        const name = std.fs.path.stem(self.path);
        const ext = self.assetType.cookedExtension();
        const filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, ext });
        errdefer allocator.free(filename);
        return .{
            .file = try output_dir.createFile(io, filename, .{}),
            .path = filename,
        };
    }
};

const testing = std.testing;

fn testDir() std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    return std.Io.Dir.openDir(cwd, testing.io, "examples/assets", .{ .iterate = true }) catch unreachable;
}

fn testFile(path: []const u8, extension: asset.Extension) SourceFile {
    return .{
        .path = path,
        .extension = extension,
        .assetType = extension.assetType(),
    };
}

test "SourceFile.hash returns non-zero for existing file" {
    const sf = testFile("meshes/triangle.glb", .glb);
    const result = try sf.hash(testDir(), testing.io);
    try testing.expect(result != 0);
}

test "SourceFile.hash is deterministic" {
    const sf = testFile("meshes/triangle.glb", .glb);
    const dir = testDir();
    const h1 = try sf.hash(dir, testing.io);
    const h2 = try sf.hash(dir, testing.io);
    try testing.expectEqual(h1, h2);
}

test "SourceFile.hash differs for different files" {
    const sf1 = testFile("meshes/triangle.glb", .glb);
    const sf2 = testFile("meshes/cube_textured.glb", .glb);
    const dir = testDir();
    const h1 = try sf1.hash(dir, testing.io);
    const h2 = try sf2.hash(dir, testing.io);
    try testing.expect(h1 != h2);
}

test "SourceFile.hash returns error for nonexistent file" {
    const sf = testFile("nonexistent_file_abc123.glb", .glb);
    try testing.expectError(error.FileNotFound, sf.hash(testDir(), testing.io));
}

test "SourceFile.hash is independent of extension field" {
    const sf_glb = testFile("meshes/triangle.glb", .glb);
    const sf_other = testFile("meshes/triangle.glb", .other);
    const dir = testDir();
    const h1 = try sf_glb.hash(dir, testing.io);
    const h2 = try sf_other.hash(dir, testing.io);
    try testing.expectEqual(h1, h2);
}

test "SourceFile.hashPath returns non-zero for non-empty path" {
    const sf = testFile("meshes/triangle.glb", .glb);
    try testing.expect(sf.hashPath() != 0);
}

test "SourceFile.hashPath is deterministic" {
    const sf = testFile("meshes/triangle.glb", .glb);
    try testing.expectEqual(sf.hashPath(), sf.hashPath());
}

test "SourceFile.hashPath differs for different paths" {
    const sf1 = testFile("meshes/triangle.glb", .glb);
    const sf2 = testFile("meshes/cube_textured.glb", .glb);
    try testing.expect(sf1.hashPath() != sf2.hashPath());
}

test "SourceFile.hashPath is independent of extension field" {
    const sf_glb = testFile("meshes/triangle.glb", .glb);
    const sf_other = testFile("meshes/triangle.glb", .other);
    try testing.expectEqual(sf_glb.hashPath(), sf_other.hashPath());
}

test "SourceFile.hashPath treats backslashes and forward slashes as equal" {
    const sf_forward = testFile("meshes/triangle.glb", .glb);
    const sf_backward = testFile("meshes\\triangle.glb", .glb);
    try testing.expectEqual(sf_forward.hashPath(), sf_backward.hashPath());
}

test "SourceFile.hashPath returns zero for empty path" {
    const sf = testFile("", .glb);
    try testing.expectEqual(FNV_OFFSET_BASIS, sf.hashPath());
}

test "SourceFile.getFileInfo returns non-zero size for existing file" {
    const sf = testFile("meshes/triangle.glb", .glb);
    const info = try sf.getFileInfo(testDir(), testing.io);
    try testing.expect(info.size != 0);
}

test "SourceFile.getFileInfo returns non-zero modified_ns for existing file" {
    const sf = testFile("meshes/triangle.glb", .glb);
    const info = try sf.getFileInfo(testDir(), testing.io);
    try testing.expect(info.modified_ns != 0);
}

test "SourceFile.getFileInfo is deterministic" {
    const sf = testFile("meshes/triangle.glb", .glb);
    const dir = testDir();
    const in1 = try sf.getFileInfo(dir, testing.io);
    const in2 = try sf.getFileInfo(dir, testing.io);
    try testing.expectEqual(in1.size, in2.size);
    try testing.expectEqual(in1.modified_ns, in2.modified_ns);
}

test "SourceFile.getFileInfo differs for different files" {
    const sf1 = testFile("meshes/triangle.glb", .glb);
    const sf2 = testFile("meshes/cube_textured.glb", .glb);
    const dir = testDir();
    const in1 = try sf1.getFileInfo(dir, testing.io);
    const in2 = try sf2.getFileInfo(dir, testing.io);
    try testing.expect(in1.size != in2.size);
}

test "SourceFile.getFileInfo returns error for nonexistent file" {
    const sf = testFile("nonexistent_file_abc123.glb", .glb);
    try testing.expectError(error.FileNotFound, sf.getFileInfo(testDir(), testing.io));
}

test "createCookedFile creates file with correct extension for mesh" {
    const sf = testFile("meshes/triangle.glb", .glb);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cooked = try sf.createCookedFile(testing.allocator, testing.io, tmp.dir);
    cooked.file.close(testing.io);
    defer testing.allocator.free(cooked.path);

    const opened = try tmp.dir.openFile(testing.io, "triangle.zmesh", .{});
    opened.close(testing.io);
}

test "createCookedFile strips directory from source path" {
    const sf = testFile("deeply/nested/model.glb", .glb);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cooked = try sf.createCookedFile(testing.allocator, testing.io, tmp.dir);
    cooked.file.close(testing.io);
    defer testing.allocator.free(cooked.path);

    const opened = try tmp.dir.openFile(testing.io, "model.zmesh", .{});
    opened.close(testing.io);
}

test "createCookedFile works for file without directory prefix" {
    const sf = testFile("cube.glb", .glb);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cooked = try sf.createCookedFile(testing.allocator, testing.io, tmp.dir);
    cooked.file.close(testing.io);
    defer testing.allocator.free(cooked.path);

    const opened = try tmp.dir.openFile(testing.io, "cube.zmesh", .{});
    opened.close(testing.io);
}

test "createCookedFile returns writable file" {
    const sf = testFile("writable_test.glb", .glb);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cooked = try sf.createCookedFile(testing.allocator, testing.io, tmp.dir);
    defer cooked.file.close(testing.io);
    defer testing.allocator.free(cooked.path);

    var buf: [4096]u8 = undefined;
    var writer = cooked.file.writer(testing.io, &buf);
    writer.interface.writeAll("hello") catch |err| {
        std.debug.print("Write failed: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "createCookedFile uses asset type extension not source extension" {
    const sf_glb = testFile("test_ext.glb", .glb);
    const sf_gltf = testFile("test_ext.gltf", .gltf);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f1 = try sf_glb.createCookedFile(testing.allocator, testing.io, tmp.dir);
    f1.file.close(testing.io);
    defer testing.allocator.free(f1.path);

    // Both .glb and .gltf map to mesh, so both produce .zmesh
    const f2 = try sf_gltf.createCookedFile(testing.allocator, testing.io, tmp.dir);
    f2.file.close(testing.io);
    defer testing.allocator.free(f2.path);

    const opened = try tmp.dir.openFile(testing.io, "test_ext.zmesh", .{});
    opened.close(testing.io);
}
