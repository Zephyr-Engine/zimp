const std = @import("std");

const Zatex = @import("../formats/ztex.zig").Zatex;
const RawTexture = @import("../assets/raw/texture.zig").RawTexture;
const CookedTexture = @import("../assets/cooked/texture.zig").CookedTexture;

const Cooker = @import("cooker.zig").Cooker;

pub fn cooker() Cooker {
    return .{ .cookFn = cookObj, .asset_type = .texture };
}

fn cookObj(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const file_bytes = try source_dir.readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(file_bytes);

    const raw = try RawTexture.init(file_path, file_bytes, allocator);
    defer raw.deinit(allocator);

    var cooked = try CookedTexture.cook(allocator, &raw);
    defer cooked.deinit(allocator);

    try Zatex.write(writer, cooked);
}
