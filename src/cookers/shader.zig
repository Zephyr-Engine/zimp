const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const asset = @import("../assets/asset.zig");
const RawShader = @import("../assets/raw/shader.zig").RawShader;
const CookedShader = @import("../assets/cooked/shader.zig").CookedShader;
const file_read = @import("../shared/file_read.zig");
const zshdr = @import("../formats/zshdr.zig");

pub fn cooker() Cooker {
    return .{
        .cookFn = cookShader,
        .asset_type = .shader,
        .outputPathFn = shaderOutputPath,
    };
}

fn cookShader(
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

    var raw = try RawShader.init(allocator, io, source_dir, file_path, file_result.bytes);
    defer raw.deinit(allocator);

    var cooked = try CookedShader.cook(allocator, &raw);
    defer cooked.deinit(allocator);

    try zshdr.write(writer, cooked);
}

fn shaderOutputPath(allocator: std.mem.Allocator, file_path: []const u8, asset_type: asset.AssetType) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{
        std.fs.path.basename(file_path),
        asset_type.cookedExtension(),
    });
}
