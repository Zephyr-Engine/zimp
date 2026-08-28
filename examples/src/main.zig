const std = @import("std");
const zimp = @import("zimp");

pub fn main() void {
    const example_asset = "meshes/triangle.zmesh";
    const asset_kind = zimp.runtime.detectKind(example_asset) orelse unreachable;
    std.debug.print("{s}: {s}\n", .{ example_asset, @tagName(asset_kind) });
}
