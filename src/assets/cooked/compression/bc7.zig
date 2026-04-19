const std = @import("std");

/// BC7 encoder stub. Source layout: width*height*4 bytes (RGBA8).
/// Implementation lands with color_srgb/packed_linear routing.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    _ = src;
    _ = width;
    _ = height;
    _ = dst;
    unreachable;
}
