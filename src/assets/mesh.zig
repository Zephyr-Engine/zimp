const std = @import("std");
const logger = @import("../logger.zig").logger;
const Map = std.AutoHashMap(u64, u32);

pub const RawVertex = struct {
    position: [3]f32,
    normal: ?[3]f32,
    tangest: ?[4]f32,
    uv0: ?[2]f32,
    uv1: ?[2]f32,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f32,

    pub fn hash(self: *const RawVertex) u64 {
        return std.hash.XxHash64.hash(0, std.mem.asBytes(self));
    }
};

pub const RawSubmesh = struct {
    index_offset: u32,
    index_count: u32,
    material_index: u16,
};

pub const RawMesh = struct {
    vertices: []RawVertex,
    indices: []u32,
    submeshes: []RawSubmesh,
    name: ?[]const u8,

    pub fn deduplicateVertices(self: *RawMesh, allocator: std.mem.Allocator) !void {
        logger.debug("Step 1: Deduplicating Vertices", .{});

        var map = Map.init(allocator);
        defer map.deinit();
        for (0.., self.vertices) |i, vertex| {
            const hash = vertex.hash();
            if (map.contains(hash)) {
                std.log.warn("FOUND DUPLICATE\n", .{});
            }

            try map.put(hash, @intCast(i));
        }
    }
};
