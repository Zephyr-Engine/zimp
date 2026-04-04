pub const RawVertex = struct {
    position: [3]f32,
    normal: ?[3]f32,
    tangest: ?[4]f32,
    uv0: ?[2]f32,
    uv1: ?[2]f32,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f32,
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
};
