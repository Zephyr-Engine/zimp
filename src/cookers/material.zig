const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const file_read = @import("../shared/file_read.zig");
const raw_material = @import("../assets/raw/material.zig");
const CookedMaterial = @import("../assets/cooked/material.zig").CookedMaterial;
const slotNameToIndex = @import("../assets/cooked/material.zig").slotNameToIndex;
const zamat = @import("../formats/zamat.zig");
const log = @import("../logger.zig");

pub fn cooker() Cooker {
    return .{ .cookFn = cookMaterial, .asset_type = .material };
}

fn cookMaterial(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    var source = try raw_material.parseMaterialSource(file_result.bytes, allocator);
    defer source.deinit(allocator);

    try validateReferences(allocator, io, source_dir, file_path, &source);

    var cooked = try CookedMaterial.cook(allocator, &source);
    defer cooked.deinit(allocator);

    try zamat.write(writer, cooked);
}

fn validateReferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    source: *const raw_material.MaterialSource,
) !void {
    const vert_path = try std.fmt.allocPrint(allocator, "{s}.vert", .{source.shader_path});
    defer allocator.free(vert_path);
    const frag_path = try std.fmt.allocPrint(allocator, "{s}.frag", .{source.shader_path});
    defer allocator.free(frag_path);

    if (!fileExists(source_dir, io, vert_path)) {
        log.err("{s}: shader '{s}' not found - missing {s}", .{ file_path, source.shader_path, vert_path });
        return error.MissingShader;
    }
    if (!fileExists(source_dir, io, frag_path)) {
        log.err("{s}: shader '{s}' not found - missing {s}", .{ file_path, source.shader_path, frag_path });
        return error.MissingShader;
    }

    for (source.textures) |slot| {
        if (!fileExists(source_dir, io, slot.texture_path)) {
            log.warn("{s}: texture '{s}' not found", .{ file_path, slot.texture_path });
        }
        if (slotNameToIndex(slot.slot_name) == null) {
            log.warn("{s}: unknown texture slot '{s}'", .{ file_path, slot.slot_name });
        }
    }
}

fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
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

test "material cooker writes zamat" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[textures]
        \\albedo = "textures/missing.png"
        \\[params]
        \\u_roughness = 0.5
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag", "void main() {}\n");

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);

    try testing.expectEqualSlices(u8, zamat.MAGIC, out[0..zamat.MAGIC.len]);
}

test "material cooker errors on missing shader" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/missing"
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.MissingShader, cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}
