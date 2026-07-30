const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;
const asset = @import("../assets/asset.zig");
const RawShader = @import("../assets/raw/shader.zig").RawShader;
const CookedShader = @import("../assets/cooked/shader.zig").CookedShader;
const path_helpers = @import("../path.zig");
const zshdr = @import("../formats/zshdr.zig");

pub fn cooker() Cooker {
    return .{ .cook_fn = cookShader, .asset_type = .shader };
}

fn cookShader(input: *const CookInput) !void {
    var raw = try RawShader.init(input.allocator, input.io, input.source_dir, input.source.path, input.bytes);
    defer raw.deinit(input.allocator);

    var cooked = try CookedShader.cook(input.allocator, &raw);
    defer cooked.deinit(input.allocator);

    try zshdr.write(input.writer, cooked);
}
