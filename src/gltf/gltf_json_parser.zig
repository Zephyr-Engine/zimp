const std = @import("std");

pub const Gltf = struct {
    scenes: []GltfScene = &.{},
    nodes: []GltfNode = &.{},
    meshes: []GltfMesh = &.{},
    accessors: []GltfAccessor = &.{},
    buffer_views: []GltfBufferView = &.{},
    buffers: []GltfBuffer = &.{},
    materials: []GltfMaterial = &.{},
    textures: []GltfTexture = &.{},
    images: []GltfImage = &.{},

    arena: ?std.heap.ArenaAllocator.State = null,
    allocator: ?std.mem.Allocator = null,

    pub fn parse(json_bytes: []const u8, allocator: std.mem.Allocator) !Gltf {
        const parsed = try std.json.parseFromSlice(Gltf, allocator, json_bytes, .{});

        var gltf = parsed.value;
        gltf.arena = parsed.arena_allocator.state;
        gltf.allocator = allocator;

        return gltf;
    }

    pub fn deinit(self: *Gltf) void {
        if (self.arena) |state| {
            var arena = state.promote(self.allocator.?);
            arena.deinit();
        }
        self.* = undefined;
    }
};

const GltfScene = struct {
    nodes: []u32,
};

const GltfNode = struct {
    name: ?[]const u8,
    mesh: ?u32,
    skin: ?u32,
    children: []u32 = &.{},
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    matrix: ?[16]f32,
};

const GltfMesh = struct {
    name: ?[]const u8,
    primitives: []GltfPrimitive,
};

const GltfPrimitive = struct {
    attributes: GltfAttributes,
    indices: ?u32,
    material: ?u32,
    mode: u32 = 4,
};

const GltfAttributes = struct {
    position: ?u32,
    normal: ?u32,
    tangent: ?u32,
    texcoord_0: ?u32,
    texcoord_1: ?u32,
    joints_0: ?u32,
    weights_0: ?u32,
};

const AccessorType = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT4,

    fn parse(str: []const u8) ?AccessorType {
        return std.meta.stringToEnum(AccessorType, str);
    }
};

const GltfAccessor = struct {
    buffer_view: ?u32,
    byte_offset: u32 = 0,
    component_type: u32,
    count: u32,
    type: AccessorType,
    min: ?[]f64,
    max: ?[]f64,
};

const GltfBufferView = struct {
    buffer: u32,
    byte_offset: u32 = 0,
    byte_length: u32,
    byte_stride: ?u32,
    target: ?u32,
};

const GltfBuffer = struct {
    byte_length: u32,
    uri: ?[]const u8,
};

const GltfMaterial = struct {
    name: ?[]const u8,
    pbr: ?GltfPbr,
    normal_texture: ?GltfTextureInfo,
    emissive_factor: ?[3]f32,
    alpha_mode: ?[]const u8,
};

const GltfPbr = struct {
    base_color_factor: [4]f32 = .{ 1, 1, 1, 1 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    base_color_texture: ?GltfTextureInfo,
    metallic_roughness_texture: ?GltfTextureInfo,
};

const GltfTextureInfo = struct {
    index: u32,
    tex_coord: u32 = 0,
    scale: ?f32,
};

const GltfTexture = struct {
    source: ?u32,
    sampler: ?u32,
};

const GltfImage = struct {
    buffer_view: ?u32,
    mime_type: ?[]const u8,
    name: ?[]const u8,
    uri: ?[]const u8,
};
