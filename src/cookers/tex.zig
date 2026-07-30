const std = @import("std");

const Zatex = @import("../formats/ztex.zig").Zatex;
const RawTexture = @import("../assets/raw/texture.zig").RawTexture;
const CookedTexture = @import("../assets/cooked/texture.zig").CookedTexture;

const Cooker = @import("cooker.zig").Cooker;
const CookInput = @import("cooker.zig").CookInput;

pub fn cooker() Cooker {
    return .{ .cook_fn = cookTexture, .asset_type = .texture };
}

fn cookTexture(input: *const CookInput) !void {
    const raw = try RawTexture.init(input.source.path, @constCast(input.bytes));
    defer raw.deinit(input.allocator);

    var cooked = try CookedTexture.cook(input.allocator, &raw);
    defer cooked.deinit(input.allocator);

    try Zatex.write(input.writer, cooked);
}
