const std = @import("std");

/// BC6H encoder stub. Source layout: width*height*6 bytes (RGB f16 little-endian).
/// Implementation lands with hdr_linear routing.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    _ = src;
    _ = width;
    _ = height;
    _ = dst;
    unreachable;
}
