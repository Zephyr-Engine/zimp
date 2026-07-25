const std = @import("std");
const zimp = @import("zimp");

pub fn main() void {
    const example_asset = "meshes/triangle.zmesh";
    const asset_type = zimp.runtime.detectType(example_asset) orelse unreachable;
    std.debug.print("{s}: {s}\n", .{ example_asset, @tagName(asset_type) });
}
