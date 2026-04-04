const std = @import("std");

pub const Gltf = struct {
    value: GltfJson,
    arena: *std.heap.ArenaAllocator,

    pub fn parse(json_bytes: []const u8, allocator: std.mem.Allocator) !Gltf {
        const parsed = try std.json.parseFromSlice(GltfJson, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        });

        return .{
            .value = parsed.value,
            .arena = parsed.arena,
        };
    }

    pub fn deinit(self: *Gltf) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
};

const GltfJson = struct {
    scenes: []GltfScene = &.{},
    nodes: []GltfNode = &.{},
    meshes: []GltfMesh = &.{},
    accessors: []GltfAccessor = &.{},
    bufferViews: []GltfBufferView = &.{},
    buffers: []GltfBuffer = &.{},
    materials: []GltfMaterial = &.{},
    textures: []GltfTexture = &.{},
    images: []GltfImage = &.{},
};

pub const GltfScene = struct {
    nodes: []u32 = &.{},
};

pub const GltfNode = struct {
    name: ?[]const u8 = null,
    mesh: ?u32 = null,
    skin: ?u32 = null,
    children: []u32 = &.{},
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
    matrix: ?[16]f32 = null,
};

pub const GltfMesh = struct {
    name: ?[]const u8 = null,
    primitives: []GltfPrimitive = &.{},
};

pub const GltfPrimitive = struct {
    attributes: GltfAttributes = .{},
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: u32 = 4,
};

pub const GltfAttributes = struct {
    POSITION: ?u32 = null,
    NORMAL: ?u32 = null,
    TANGENT: ?u32 = null,
    TEXCOORD_0: ?u32 = null,
    TEXCOORD_1: ?u32 = null,
    JOINTS_0: ?u32 = null,
    WEIGHTS_0: ?u32 = null,
};

pub const AccessorType = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT4,
};

pub const GltfAccessor = struct {
    bufferView: ?u32 = null,
    byteOffset: u32 = 0,
    componentType: u32,
    count: u32,
    type: AccessorType,
    min: ?[]f64 = null,
    max: ?[]f64 = null,
};

pub const GltfBufferView = struct {
    buffer: u32,
    byteOffset: u32 = 0,
    byteLength: u32,
    byteStride: ?u32 = null,
    target: ?u32 = null,
};

pub const GltfBuffer = struct {
    byteLength: u32,
    uri: ?[]const u8 = null,
};

pub const GltfMaterial = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?GltfPbr = null,
    normalTexture: ?GltfTextureInfo = null,
    emissiveFactor: ?[3]f32 = null,
    alphaMode: ?[]const u8 = null,
};

pub const GltfPbr = struct {
    baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
    metallicFactor: f32 = 1.0,
    roughnessFactor: f32 = 1.0,
    baseColorTexture: ?GltfTextureInfo = null,
    metallicRoughnessTexture: ?GltfTextureInfo = null,
};

pub const GltfTextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    scale: ?f32 = null,
};

pub const GltfTexture = struct {
    source: ?u32 = null,
    sampler: ?u32 = null,
};

pub const GltfImage = struct {
    bufferView: ?u32 = null,
    mimeType: ?[]const u8 = null,
    name: ?[]const u8 = null,
    uri: ?[]const u8 = null,
};
