const std = @import("std");

const CookedShader = @import("../assets/cooked/shader.zig").CookedShader;
const RawShader = @import("../assets/raw/shader.zig").RawShader;
const builtin = @import("../builtin/registry.zig");
const CookInput = @import("cooker.zig").CookInput;
const zshdr = @import("../formats/zshdr.zig");
const asset = @import("../assets/asset.zig");
const path_helpers = @import("../path.zig");
const Cooker = @import("cooker.zig").Cooker;

pub fn cooker() Cooker {
    return .{ .cook_fn = cookShader, .asset_type = .shader };
}

fn cookShader(input: *const CookInput) !void {
    const source = builtin.Source{
        .path = input.source.path,
        .bytes = input.bytes,
    };
    var raw = try RawShader.init(input.allocator, input.io, input.source_dir, &source);
    defer raw.deinit(input.allocator);

    var cooked = try CookedShader.cook(input.allocator, &raw);
    defer cooked.deinit(input.allocator);

    try zshdr.write(input.writer, cooked);
}
