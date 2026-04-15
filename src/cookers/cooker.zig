const std = @import("std");

const asset = @import("../assets/asset.zig");
const Extension = asset.Extension;
const AssetType = asset.AssetType;

pub const Cooker = struct {
    cookFn: *const fn (
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        file_path: []const u8,
        writer: *std.Io.Writer,
    ) anyerror!void,
    asset_type: AssetType,

    pub fn cook(
        self: Cooker,
        allocator: std.mem.Allocator,
        io: std.Io,
        source_dir: std.Io.Dir,
        file_path: []const u8,
        writer: *std.Io.Writer,
    ) !void {
        return self.cookFn(allocator, io, source_dir, file_path, writer);
    }
};

const glb_cooker = @import("glb.zig").cooker();
const obj_cooker = @import("obj.zig").cooker();
const tex_cooker = @import("tex.zig").cooker();

pub const cooker_registry = std.EnumArray(Extension, ?Cooker).init(.{
    .glb = glb_cooker,
    .gltf = glb_cooker,
    .obj = obj_cooker,
    .png = tex_cooker,
    .jpeg = tex_cooker,
    .jpg = tex_cooker,
    .other = null,
});

comptime {
    for (std.meta.fields(Extension)) |field| {
        const ext: Extension = @enumFromInt(field.value);
        if (cooker_registry.get(ext)) |cooker| {
            if (cooker.asset_type != ext.assetType()) {
                @compileError("Cooker for extension '" ++ field.name ++ "' has asset_type that does not match asset.zig mapping");
            }
        }
    }
}

const testing = std.testing;

var test_called: bool = false;

fn stubCook(_: std.mem.Allocator, _: std.Io, _: std.Io.Dir, _: []const u8, _: *std.Io.Writer) anyerror!void {
    test_called = true;
}

fn failingCook(_: std.mem.Allocator, _: std.Io, _: std.Io.Dir, _: []const u8, _: *std.Io.Writer) anyerror!void {
    return error.TestCookFailed;
}

test "Cooker.cook calls the provided function pointer" {
    test_called = false;
    const cooker = Cooker{ .cookFn = stubCook, .asset_type = .mesh };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    try cooker.cook(testing.allocator, testing.io, std.Io.Dir.cwd(), "", &writer);

    try testing.expect(test_called);
}

test "Cooker.cook propagates errors from cookFn" {
    const cooker = Cooker{ .cookFn = failingCook, .asset_type = .mesh };

    var buf: [1]u8 = .{0};
    var writer = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.TestCookFailed, cooker.cook(testing.allocator, testing.io, std.Io.Dir.cwd(), "", &writer));
}

test "Cooker struct contains cookFn and asset_type" {
    try testing.expect(@sizeOf(Cooker) > @sizeOf(*const fn (std.mem.Allocator, std.Io, std.Io.Dir, []const u8, *std.Io.Writer) anyerror!void));
    try testing.expect(@hasField(Cooker, "cookFn"));
    try testing.expect(@hasField(Cooker, "asset_type"));
}

test "cooker_registry contains glb" {
    try testing.expect(cooker_registry.get(.glb) != null);
}

test "cooker_registry contains gltf" {
    try testing.expect(cooker_registry.get(.gltf) != null);
}

test "cooker_registry returns null for unknown extension" {
    try testing.expectEqual(@as(?Cooker, null), cooker_registry.get(.other));
}

test "cooker_registry maps glb and gltf to same cooker" {
    const glb = cooker_registry.get(.glb).?;
    const gltf = cooker_registry.get(.gltf).?;
    try testing.expectEqual(glb.cookFn, gltf.cookFn);
}
