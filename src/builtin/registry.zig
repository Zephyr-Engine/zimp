const std = @import("std");

const AssetId = @import("../id/id_types.zig").AssetId;

pub const PREFIX = "zephyr/";

pub const Source = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const shaders = [_]Source{
    .{ .path = PREFIX ++ "standard.vert", .bytes = @embedFile("shaders/standard.vert") },
    .{ .path = PREFIX ++ "standard.frag", .bytes = @embedFile("shaders/standard.frag") },
    .{ .path = PREFIX ++ "error.vert", .bytes = @embedFile("shaders/error.vert") },
    .{ .path = PREFIX ++ "error.frag", .bytes = @embedFile("shaders/error.frag") },
};

pub const materials = [_]Source{
    .{ .path = PREFIX ++ "error.zamat", .bytes = @embedFile("materials/error.zamat") },
};

pub fn isBuiltin(path: []const u8) bool {
    return std.mem.startsWith(u8, path, PREFIX);
}

pub fn find(path: []const u8) ?Source {
    for (shaders) |s| {
        if (std.mem.eql(u8, s.path, path)) {
            return s;
        }
    }

    for (materials) |s| {
        if (std.mem.eql(u8, s.path, path)) {
            return s;
        }
    }

    return null;
}

pub fn idFor(path: []const u8) AssetId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("zephyr.builtin.v1:");
    hasher.update(path);
    var out: [16]u8 = undefined;
    hasher.final(&out);
    out[6] = (out[6] & 0x0f) | 0x50; // version 5
    out[8] = (out[8] & 0x3f) | 0x80; // RFC 4122 variant
    return AssetId.fromBytes(out);
}

pub const error_material_id = idFor(PREFIX ++ "error.zamat");
