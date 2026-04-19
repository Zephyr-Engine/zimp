const std = @import("std");

/// BC5 encoder stub. Source layout: width*height*2 bytes (R, G interleaved).
/// BC5 is two BC4 blocks back-to-back: first 8 bytes encode R, next 8 encode G.
/// Implementation lands with normal_linear routing.
pub fn encode(src: []const u8, width: u32, height: u32, dst: []u8) void {
    _ = src;
    _ = width;
    _ = height;
    _ = dst;
    unreachable;
}
