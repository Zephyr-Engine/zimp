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

pub const GltfJson = struct {
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

    pub fn componentCount(self: AccessorType) usize {
        return switch (self) {
            .SCALAR => 1,
            .VEC2 => 2,
            .VEC3 => 3,
            .VEC4 => 4,
            .MAT4 => 16,
        };
    }
};

pub const GltfAccessorError = error{
    OutOfBounds,
    OutOfMemory,
};

pub const GltfAccessor = struct {
    bufferView: ?u32 = null,
    byteOffset: u32 = 0,
    componentType: AccessorComponentType,
    count: u32,
    type: AccessorType,
    min: ?[]f64 = null,
    max: ?[]f64 = null,

    pub fn readAccessorSlice(self: *const GltfAccessor, comptime T: type, allocator: std.mem.Allocator, buffer_views: []GltfBufferView, bin: []const u8) GltfAccessorError![]align(1) const T {
        const bytes = try self.readAccessor(allocator, buffer_views, bin);
        return std.mem.bytesAsSlice(T, bytes);
    }

    pub fn readAccessor(self: *const GltfAccessor, allocator: std.mem.Allocator, buffer_views: []GltfBufferView, bin: []const u8) GltfAccessorError![]const u8 {
        const buffer_view_value = self.bufferView orelse return &.{};
        const buffer_view = buffer_views[buffer_view_value];

        const start = self.byteOffset + buffer_view.byteOffset;
        const component_size = self.componentType.size();
        const num_components = self.type.componentCount();
        const element_size = component_size * num_components;
        const stride = buffer_view.byteStride orelse element_size;

        // Tightly packed — return a direct slice, no copy needed
        if (stride == element_size) {
            const end = start + element_size * self.count;
            if (end > bin.len) {
                return GltfAccessorError.OutOfBounds;
            }
            return bin[start..end];
        }

        // Interleaved — copy each element's data into a contiguous buffer
        const total = element_size * self.count;
        if (start + stride * (self.count - 1) + element_size > bin.len) {
            return GltfAccessorError.OutOfBounds;
        }

        const out = try allocator.alloc(u8, total);
        for (0..self.count) |i| {
            const src_offset = start + stride * i;
            @memcpy(out[element_size * i ..][0..element_size], bin[src_offset..][0..element_size]);
        }

        return out;
    }
};

pub const AccessorComponentType = enum(u32) {
    BYTE = 5120,
    UNSIGNED_BYTE = 5121,
    SHORT = 5122,
    UNSIGNED_SHORT = 5123,
    UNSIGNED_INT = 5125,
    FLOAT = 5126,

    pub fn size(self: AccessorComponentType) usize {
        return switch (self) {
            .BYTE, .UNSIGNED_BYTE => 1,
            .SHORT, .UNSIGNED_SHORT => 2,
            .FLOAT, .UNSIGNED_INT => 4,
        };
    }
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

const testing = std.testing;

test "parse minimal gltf" {
    var gltf = try Gltf.parse("{}", testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(0, gltf.value.scenes.len);
    try testing.expectEqual(0, gltf.value.nodes.len);
    try testing.expectEqual(0, gltf.value.meshes.len);
    try testing.expectEqual(0, gltf.value.accessors.len);
    try testing.expectEqual(0, gltf.value.bufferViews.len);
    try testing.expectEqual(0, gltf.value.buffers.len);
    try testing.expectEqual(0, gltf.value.materials.len);
    try testing.expectEqual(0, gltf.value.textures.len);
    try testing.expectEqual(0, gltf.value.images.len);
}

test "parse ignores unknown fields" {
    var gltf = try Gltf.parse(
        \\{"asset":{"version":"2.0"},"scene":0,"samplers":[{}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(0, gltf.value.nodes.len);
}

test "parse scenes" {
    var gltf = try Gltf.parse(
        \\{"scenes":[{"nodes":[0,1]},{"nodes":[2]}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.scenes.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, gltf.value.scenes[0].nodes);
    try testing.expectEqualSlices(u32, &.{2}, gltf.value.scenes[1].nodes);
}

test "parse nodes with defaults" {
    var gltf = try Gltf.parse(
        \\{"nodes":[{"name":"Camera"},{}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.nodes.len);

    const cam = gltf.value.nodes[0];
    try testing.expectEqualStrings("Camera", cam.name.?);
    try testing.expectEqual(null, cam.mesh);
    try testing.expectEqual(null, cam.skin);
    try testing.expectEqual(0, cam.children.len);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, cam.translation);
    try testing.expectEqual([4]f32{ 0, 0, 0, 1 }, cam.rotation);
    try testing.expectEqual([3]f32{ 1, 1, 1 }, cam.scale);
    try testing.expectEqual(null, cam.matrix);

    const empty = gltf.value.nodes[1];
    try testing.expectEqual(null, empty.name);
}

test "parse node with all fields" {
    var gltf = try Gltf.parse(
        \\{"nodes":[{
        \\  "name":"Arm","mesh":2,"skin":1,
        \\  "children":[3,4],
        \\  "translation":[1.0,2.0,3.0],
        \\  "rotation":[0.0,0.707,0.0,0.707],
        \\  "scale":[2.0,2.0,2.0]
        \\}]}
    , testing.allocator);
    defer gltf.deinit();

    const node = gltf.value.nodes[0];
    try testing.expectEqualStrings("Arm", node.name.?);
    try testing.expectEqual(2, node.mesh.?);
    try testing.expectEqual(1, node.skin.?);
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, node.children);
    try testing.expectEqual([3]f32{ 1.0, 2.0, 3.0 }, node.translation);
    try testing.expectEqual([3]f32{ 2.0, 2.0, 2.0 }, node.scale);
}

test "parse meshes and primitives" {
    var gltf = try Gltf.parse(
        \\{"meshes":[{
        \\  "name":"Cube",
        \\  "primitives":[{
        \\    "attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3},
        \\    "indices":0,
        \\    "material":0
        \\  }]
        \\}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.meshes.len);
    try testing.expectEqualStrings("Cube", gltf.value.meshes[0].name.?);

    const prim = gltf.value.meshes[0].primitives[0];
    try testing.expectEqual(1, prim.attributes.POSITION.?);
    try testing.expectEqual(2, prim.attributes.NORMAL.?);
    try testing.expectEqual(3, prim.attributes.TEXCOORD_0.?);
    try testing.expectEqual(null, prim.attributes.TANGENT);
    try testing.expectEqual(null, prim.attributes.TEXCOORD_1);
    try testing.expectEqual(null, prim.attributes.JOINTS_0);
    try testing.expectEqual(null, prim.attributes.WEIGHTS_0);
    try testing.expectEqual(0, prim.indices.?);
    try testing.expectEqual(0, prim.material.?);
    try testing.expectEqual(4, prim.mode);
}

test "parse primitive with explicit mode" {
    var gltf = try Gltf.parse(
        \\{"meshes":[{"primitives":[{"attributes":{},"mode":1}]}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.meshes[0].primitives[0].mode);
}

test "parse accessors" {
    var gltf = try Gltf.parse(
        \\{"accessors":[
        \\  {"bufferView":0,"componentType":5123,"count":36,"type":"SCALAR","max":[23],"min":[0]},
        \\  {"componentType":5126,"count":24,"type":"VEC3"},
        \\  {"bufferView":3,"byteOffset":12,"componentType":5126,"count":24,"type":"VEC2"}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(3, gltf.value.accessors.len);

    const a0 = gltf.value.accessors[0];
    try testing.expectEqual(0, a0.bufferView.?);
    try testing.expectEqual(0, a0.byteOffset);
    try testing.expectEqual(.UNSIGNED_SHORT, a0.componentType);
    try testing.expectEqual(36, a0.count);
    try testing.expectEqual(.SCALAR, a0.type);
    try testing.expectEqual(1, a0.max.?.len);
    try testing.expectEqual(1, a0.min.?.len);

    const a1 = gltf.value.accessors[1];
    try testing.expectEqual(null, a1.bufferView);
    try testing.expectEqual(.VEC3, a1.type);
    try testing.expectEqual(null, a1.max);
    try testing.expectEqual(null, a1.min);

    const a2 = gltf.value.accessors[2];
    try testing.expectEqual(12, a2.byteOffset);
    try testing.expectEqual(.VEC2, a2.type);
}

test "parse all accessor types" {
    var gltf = try Gltf.parse(
        \\{"accessors":[
        \\  {"componentType":5126,"count":1,"type":"SCALAR"},
        \\  {"componentType":5126,"count":1,"type":"VEC2"},
        \\  {"componentType":5126,"count":1,"type":"VEC3"},
        \\  {"componentType":5126,"count":1,"type":"VEC4"},
        \\  {"componentType":5126,"count":1,"type":"MAT4"}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(.SCALAR, gltf.value.accessors[0].type);
    try testing.expectEqual(.VEC2, gltf.value.accessors[1].type);
    try testing.expectEqual(.VEC3, gltf.value.accessors[2].type);
    try testing.expectEqual(.VEC4, gltf.value.accessors[3].type);
    try testing.expectEqual(.MAT4, gltf.value.accessors[4].type);
}

test "parse buffer views" {
    var gltf = try Gltf.parse(
        \\{"bufferViews":[
        \\  {"buffer":0,"byteOffset":0,"byteLength":72,"target":34963},
        \\  {"buffer":0,"byteOffset":72,"byteLength":288,"byteStride":12,"target":34962},
        \\  {"buffer":0,"byteOffset":840,"byteLength":81}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(3, gltf.value.bufferViews.len);

    const bv0 = gltf.value.bufferViews[0];
    try testing.expectEqual(0, bv0.buffer);
    try testing.expectEqual(0, bv0.byteOffset);
    try testing.expectEqual(72, bv0.byteLength);
    try testing.expectEqual(34963, bv0.target.?);
    try testing.expectEqual(null, bv0.byteStride);

    const bv1 = gltf.value.bufferViews[1];
    try testing.expectEqual(12, bv1.byteStride.?);

    const bv2 = gltf.value.bufferViews[2];
    try testing.expectEqual(null, bv2.target);
}

test "parse buffers" {
    var gltf = try Gltf.parse(
        \\{"buffers":[{"byteLength":1084},{"byteLength":256,"uri":"ext.bin"}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.buffers.len);
    try testing.expectEqual(1084, gltf.value.buffers[0].byteLength);
    try testing.expectEqual(null, gltf.value.buffers[0].uri);
    try testing.expectEqual(256, gltf.value.buffers[1].byteLength);
    try testing.expectEqualStrings("ext.bin", gltf.value.buffers[1].uri.?);
}

test "parse materials with pbr" {
    var gltf = try Gltf.parse(
        \\{"materials":[{
        \\  "name":"WoodMaterial",
        \\  "pbrMetallicRoughness":{
        \\    "baseColorFactor":[0.8,0.2,0.2,1.0],
        \\    "metallicFactor":0.0,
        \\    "roughnessFactor":0.8,
        \\    "baseColorTexture":{"index":0},
        \\    "metallicRoughnessTexture":{"index":2}
        \\  },
        \\  "normalTexture":{"index":1,"scale":1.0},
        \\  "emissiveFactor":[0.0,0.0,0.0],
        \\  "alphaMode":"OPAQUE"
        \\}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.materials.len);
    const mat = gltf.value.materials[0];
    try testing.expectEqualStrings("WoodMaterial", mat.name.?);
    try testing.expectEqualStrings("OPAQUE", mat.alphaMode.?);
    try testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, mat.emissiveFactor.?);

    const pbr = mat.pbrMetallicRoughness.?;
    try testing.expectEqual([4]f32{ 0.8, 0.2, 0.2, 1.0 }, pbr.baseColorFactor);
    try testing.expectEqual(@as(f32, 0.0), pbr.metallicFactor);
    try testing.expectEqual(@as(f32, 0.8), pbr.roughnessFactor);
    try testing.expectEqual(0, pbr.baseColorTexture.?.index);
    try testing.expectEqual(2, pbr.metallicRoughnessTexture.?.index);

    const normal = mat.normalTexture.?;
    try testing.expectEqual(1, normal.index);
    try testing.expectEqual(@as(f32, 1.0), normal.scale.?);
    try testing.expectEqual(0, normal.texCoord);
}

test "parse material with pbr defaults" {
    var gltf = try Gltf.parse(
        \\{"materials":[{"pbrMetallicRoughness":{}}]}
    , testing.allocator);
    defer gltf.deinit();

    const pbr = gltf.value.materials[0].pbrMetallicRoughness.?;
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, pbr.baseColorFactor);
    try testing.expectEqual(@as(f32, 1.0), pbr.metallicFactor);
    try testing.expectEqual(@as(f32, 1.0), pbr.roughnessFactor);
    try testing.expectEqual(null, pbr.baseColorTexture);
    try testing.expectEqual(null, pbr.metallicRoughnessTexture);
}

test "parse material with no pbr" {
    var gltf = try Gltf.parse(
        \\{"materials":[{"name":"Simple"}]}
    , testing.allocator);
    defer gltf.deinit();

    const mat = gltf.value.materials[0];
    try testing.expectEqualStrings("Simple", mat.name.?);
    try testing.expectEqual(null, mat.pbrMetallicRoughness);
    try testing.expectEqual(null, mat.normalTexture);
    try testing.expectEqual(null, mat.emissiveFactor);
    try testing.expectEqual(null, mat.alphaMode);
}

test "parse textures" {
    var gltf = try Gltf.parse(
        \\{"textures":[{"source":0,"sampler":0},{"source":1},{}]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(3, gltf.value.textures.len);
    try testing.expectEqual(0, gltf.value.textures[0].source.?);
    try testing.expectEqual(0, gltf.value.textures[0].sampler.?);
    try testing.expectEqual(1, gltf.value.textures[1].source.?);
    try testing.expectEqual(null, gltf.value.textures[1].sampler);
    try testing.expectEqual(null, gltf.value.textures[2].source);
}

test "parse images with buffer view" {
    var gltf = try Gltf.parse(
        \\{"images":[
        \\  {"bufferView":4,"mimeType":"image/png","name":"albedo"},
        \\  {"uri":"texture.png","name":"external"}
        \\]}
    , testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(2, gltf.value.images.len);

    const img0 = gltf.value.images[0];
    try testing.expectEqual(4, img0.bufferView.?);
    try testing.expectEqualStrings("image/png", img0.mimeType.?);
    try testing.expectEqualStrings("albedo", img0.name.?);
    try testing.expectEqual(null, img0.uri);

    const img1 = gltf.value.images[1];
    try testing.expectEqual(null, img1.bufferView);
    try testing.expectEqual(null, img1.mimeType);
    try testing.expectEqualStrings("external", img1.name.?);
    try testing.expectEqualStrings("texture.png", img1.uri.?);
}

test "parse full triangle gltf" {
    const json_str =
        \\{
        \\  "scenes":[{"nodes":[0]}],
        \\  "nodes":[{"mesh":0,"name":"Triangle"}],
        \\  "meshes":[{"primitives":[{"attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3},"indices":0,"material":0}],"name":"TriangleMesh"}],
        \\  "materials":[{"name":"DefaultMaterial","pbrMetallicRoughness":{"baseColorFactor":[0.8,0.2,0.2,1.0],"metallicFactor":0.0,"roughnessFactor":0.8}}],
        \\  "accessors":[
        \\    {"bufferView":0,"componentType":5123,"count":3,"type":"SCALAR","max":[2],"min":[0]},
        \\    {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        \\    {"bufferView":2,"componentType":5126,"count":3,"type":"VEC3"},
        \\    {"bufferView":3,"componentType":5126,"count":3,"type":"VEC2"}
        \\  ],
        \\  "bufferViews":[
        \\    {"buffer":0,"byteOffset":0,"byteLength":6,"target":34963},
        \\    {"buffer":0,"byteOffset":8,"byteLength":36,"target":34962},
        \\    {"buffer":0,"byteOffset":44,"byteLength":36,"target":34962},
        \\    {"buffer":0,"byteOffset":80,"byteLength":24,"target":34962}
        \\  ],
        \\  "buffers":[{"byteLength":104}]
        \\}
    ;

    var gltf = try Gltf.parse(json_str, testing.allocator);
    defer gltf.deinit();

    try testing.expectEqual(1, gltf.value.scenes.len);
    try testing.expectEqual(1, gltf.value.nodes.len);
    try testing.expectEqual(1, gltf.value.meshes.len);
    try testing.expectEqual(1, gltf.value.materials.len);
    try testing.expectEqual(4, gltf.value.accessors.len);
    try testing.expectEqual(4, gltf.value.bufferViews.len);
    try testing.expectEqual(1, gltf.value.buffers.len);
    try testing.expectEqual(104, gltf.value.buffers[0].byteLength);
}

test "parse returns error on invalid json" {
    try testing.expectError(error.SyntaxError, Gltf.parse("{invalid", testing.allocator));
}

test "parse returns error on missing required field" {
    try testing.expectError(error.MissingField, Gltf.parse(
        \\{"accessors":[{"count":1,"type":"SCALAR"}]}
    , testing.allocator));
}

test "parse returns error on invalid accessor type" {
    try testing.expectError(error.InvalidEnumTag, Gltf.parse(
        \\{"accessors":[{"componentType":5126,"count":1,"type":"INVALID"}]}
    , testing.allocator));
}

test "deinit frees memory" {
    var gltf = try Gltf.parse(
        \\{"nodes":[{"name":"A"},{"name":"B"},{"name":"C"}],"buffers":[{"byteLength":100}]}
    , testing.allocator);
    gltf.deinit();
}
