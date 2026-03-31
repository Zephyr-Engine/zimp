const std = @import("std");

const asset = @import("asset.zig");

pub const SourceFile = struct {
    path: []const u8,
    extension: asset.Extension,
    assetType: asset.AssetType,

    pub fn hash(self: SourceFile, io: std.Io) !u64 {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, self.path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var fr = file.reader(io, &buf);
        var reader = &fr.interface;

        var hr = reader.hashed(std.hash.XxHash64.init(0), &buf);
        _ = try hr.reader.discardRemaining();

        return hr.hasher.final();
    }
};

const testing = std.testing;

fn testFile(path: []const u8, extension: asset.Extension) SourceFile {
    return .{
        .path = path,
        .extension = extension,
        .assetType = extension.assetType(),
    };
}

test "SourceFile.hash returns non-zero for existing file" {
    const sf = testFile("examples/assets/meshes/triangle.glb", .glb);
    const result = try sf.hash(testing.io);
    try testing.expect(result != 0);
}

test "SourceFile.hash is deterministic" {
    const sf = testFile("examples/assets/meshes/triangle.glb", .glb);
    const h1 = try sf.hash(testing.io);
    const h2 = try sf.hash(testing.io);
    try testing.expectEqual(h1, h2);
}

test "SourceFile.hash differs for different files" {
    const sf1 = testFile("examples/assets/meshes/triangle.glb", .glb);
    const sf2 = testFile("examples/assets/meshes/cube_textured.glb", .glb);
    const h1 = try sf1.hash(testing.io);
    const h2 = try sf2.hash(testing.io);
    try testing.expect(h1 != h2);
}

test "SourceFile.hash returns error for nonexistent file" {
    const sf = testFile("nonexistent_file_abc123.glb", .glb);
    try testing.expectError(error.FileNotFound, sf.hash(testing.io));
}

test "SourceFile.hash is independent of extension field" {
    const sf_glb = testFile("examples/assets/meshes/triangle.glb", .glb);
    const sf_other = testFile("examples/assets/meshes/triangle.glb", .other);
    const h1 = try sf_glb.hash(testing.io);
    const h2 = try sf_other.hash(testing.io);
    try testing.expectEqual(h1, h2);
}
