const std = @import("std");

const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const file_read = @import("../../shared/file_read.zig");
const GLBFile = @import("glb_parser.zig").GLBFile;
const Gltf = @import("gltf_json_parser.zig").Gltf;
const GltfJson = @import("gltf_json_parser.zig").GltfJson;
const GltfMaterial = @import("gltf_json_parser.zig").GltfMaterial;
const GltfPbr = @import("gltf_json_parser.zig").GltfPbr;
const GltfTextureInfo = @import("gltf_json_parser.zig").GltfTextureInfo;
const GltfDocument = @import("document.zig").GltfDocument;
const Extension = @import("../../assets/asset.zig").Extension;
const resolveRelativeUri = @import("document.zig").resolveRelativeUri;
const log = @import("../../logger.zig");

const DEFAULT_SHADER = "shaders/basic";
const GENERATED_MATERIAL_DIR = "generated/materials";
const GENERATED_TEXTURE_DIR = "generated/textures";

pub fn generateForSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    sources: []const SourceFile,
) !usize {
    var generated: usize = 0;
    for (sources) |source| {
        if (source.extension != .glb and source.extension != .gltf) continue;
        generated += generateForSource(allocator, io, source_dir, source.path, source.extension) catch |err| {
            log.warn("Failed to auto-generate materials for '{s}': {s}", .{ source.path, @errorName(err) });
            continue;
        };
    }
    return generated;
}

pub fn generateForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    extension: Extension,
) !usize {
    switch (extension) {
        .glb => {
            const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path, .{
                .chunk_size = 256 * 1024,
            });
            defer allocator.free(file_result.bytes);

            const glb_file = try GLBFile.parse(allocator, file_result.bytes);
            defer allocator.destroy(glb_file);

            var gltf = try Gltf.parse(glb_file.json, allocator);
            defer gltf.deinit();

            const buffers = [_][]const u8{glb_file.bin};
            return generateFromGltf(allocator, io, source_dir, file_path, &gltf.value, &buffers);
        },
        .gltf => {
            var document = try GltfDocument.loadGltf(allocator, io, source_dir, file_path);
            defer document.deinit();
            return generateFromGltf(allocator, io, source_dir, file_path, &document.gltf.value, document.buffers);
        },
        else => return 0,
    }
}

pub fn generateFromGltf(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
) !usize {
    if (gltf.materials.len == 0) return 0;

    try source_dir.createDirPath(io, GENERATED_MATERIAL_DIR);
    try source_dir.createDirPath(io, GENERATED_TEXTURE_DIR);

    var generated: usize = 0;
    for (gltf.materials, 0..) |material, i| {
        const material_name = material.name orelse try std.fmt.allocPrint(allocator, "material_{d}", .{i});
        const allocated_name = material.name == null;
        defer if (allocated_name) allocator.free(material_name);

        const output_path = try generatedMaterialPath(allocator, source_path, material_name);
        defer allocator.free(output_path);

        const hand_path = try handwrittenMaterialPath(allocator, std.fs.path.basename(output_path));
        defer allocator.free(hand_path);

        if (fileExists(source_dir, io, hand_path) or fileExists(source_dir, io, output_path)) {
            continue;
        }

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try writeMaterialText(&text, allocator, io, source_dir, source_path, gltf, buffers, material, material_name);

        const file = try source_dir.createFile(io, output_path, .{});
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(text.items);
        try writer.interface.flush();
        file.close(io);

        generated += 1;
        log.debug("Generated material '{s}' from '{s}'", .{ output_path, source_path });
    }

    return generated;
}

fn writeMaterialText(
    text: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    material: GltfMaterial,
    material_name: []const u8,
) !void {
    try appendPrint(text, allocator,
        \\# Auto-generated from {s} - {s}
        \\[material]
        \\shader = "{s}"
        \\alpha_mode = "{s}"
        \\
        \\[textures]
        \\
    , .{ source_path, material_name, DEFAULT_SHADER, mapAlphaMode(material.alphaMode) });

    if (material.pbrMetallicRoughness) |pbr| {
        if (pbr.baseColorTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "albedo", info);
        if (pbr.metallicRoughnessTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "roughness_metallic", info);
    }
    if (material.normalTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "normal", info);
    if (material.occlusionTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "ao", info);
    if (material.emissiveTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "emissive", info);

    try text.appendSlice(allocator,
        \\
        \\[params]
        \\
    );

    const pbr = material.pbrMetallicRoughness orelse GltfPbr{};
    try appendVec4(text, allocator, "u_base_color", pbr.baseColorFactor);
    try appendFloat(text, allocator, "u_metallic", pbr.metallicFactor);
    try appendFloat(text, allocator, "u_roughness", pbr.roughnessFactor);
    try appendVec3(text, allocator, "u_emissive", material.emissiveFactor orelse .{ 0, 0, 0 });
}

fn appendTexture(
    text: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    slot_name: []const u8,
    info: GltfTextureInfo,
) !void {
    const path = try texturePath(allocator, io, source_dir, source_path, gltf, buffers, info.index);
    defer allocator.free(path);
    try appendPrint(text, allocator, "{s} = \"{s}\"\n", .{ slot_name, path });
}

fn texturePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
    buffers: []const []const u8,
    texture_index: u32,
) ![]u8 {
    if (texture_index >= gltf.textures.len) return error.TextureIndexOutOfBounds;
    const image_index = gltf.textures[texture_index].source orelse return error.TextureMissingSource;
    if (image_index >= gltf.images.len) return error.ImageIndexOutOfBounds;
    const image = gltf.images[image_index];

    if (image.uri) |uri| {
        return resolveRelativeUri(allocator, source_path, uri);
    }

    const buffer_view_index = image.bufferView orelse return error.ImageMissingData;
    if (buffer_view_index >= gltf.bufferViews.len) return error.BufferViewIndexOutOfBounds;
    const view = gltf.bufferViews[buffer_view_index];
    if (view.buffer >= buffers.len) return error.BufferIndexOutOfBounds;
    const buffer = buffers[view.buffer];
    const start: usize = view.byteOffset;
    const end = start + view.byteLength;
    if (end > buffer.len) return error.ImageOutOfBounds;

    const path = try generatedTexturePath(allocator, source_path, image.name, image_index, image.mimeType);
    errdefer allocator.free(path);
    if (!fileExists(source_dir, io, path)) {
        const file = try source_dir.createFile(io, path, .{});
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(buffer[start..end]);
        try writer.interface.flush();
        file.close(io);
    }
    return path;
}

fn mapAlphaMode(value: ?[]const u8) []const u8 {
    const mode = value orelse return "solid";
    if (std.ascii.eqlIgnoreCase(mode, "MASK")) return "alpha_test";
    if (std.ascii.eqlIgnoreCase(mode, "BLEND")) return "alpha_blend";
    return "solid";
}

fn appendFloat(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: f32) !void {
    try appendPrint(text, allocator, "{s} = {d:.6}\n", .{ name, value });
}

fn appendVec3(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: [3]f32) !void {
    try appendPrint(text, allocator, "{s} = [{d}, {d}, {d}]\n", .{ name, value[0], value[1], value[2] });
}

fn appendVec4(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: [4]f32) !void {
    try appendPrint(text, allocator, "{s} = [{d}, {d}, {d}, {d}]\n", .{ name, value[0], value[1], value[2], value[3] });
}

fn appendPrint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn generatedMaterialPath(allocator: std.mem.Allocator, source_path: []const u8, material_name: []const u8) ![]u8 {
    const source_stem = std.fs.path.stem(source_path);
    const safe_name = try sanitizeName(allocator, material_name);
    defer allocator.free(safe_name);
    return std.fmt.allocPrint(allocator, GENERATED_MATERIAL_DIR ++ "/{s}_{s}.zamat", .{ source_stem, safe_name });
}

fn handwrittenMaterialPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "materials/{s}", .{filename});
}

fn generatedTexturePath(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    image_name: ?[]const u8,
    image_index: usize,
    mime_type: ?[]const u8,
) ![]u8 {
    const source_stem = std.fs.path.stem(source_path);
    const raw_name = image_name orelse try std.fmt.allocPrint(allocator, "image_{d}", .{image_index});
    const allocated_name = image_name == null;
    defer if (allocated_name) allocator.free(raw_name);

    const safe_name = try sanitizeName(allocator, raw_name);
    defer allocator.free(safe_name);
    return std.fmt.allocPrint(allocator, GENERATED_TEXTURE_DIR ++ "/{s}_{s}.{s}", .{ source_stem, safe_name, imageExtension(mime_type) });
}

fn imageExtension(mime_type: ?[]const u8) []const u8 {
    const mime = mime_type orelse return "bin";
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/jpg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/vnd-ms.dds")) return "dds";
    if (std.mem.eql(u8, mime, "image/ktx2")) return "ktx2";
    return "bin";
}

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, @max(name.len, 1));
    if (name.len == 0) {
        out[0] = '_';
        return out;
    }

    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => c,
            else => '_',
        };
    }
    return out;
}

fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

const testing = std.testing;

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dirname| {
        try dir.createDirPath(testing.io, dirname);
    }
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

fn readTestFile(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const result = try file_read.readFileAllocChunked(allocator, testing.io, dir, path, .{ .chunk_size = 4096 });
    return result.bytes;
}

test "generateFromGltf writes material with external texture and params" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"WoodMaterial","pbrMetallicRoughness":{"baseColorTexture":{"index":0},"baseColorFactor":[1,1,1,1],"metallicFactor":0.0,"roughnessFactor":1.0}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"uri":"cube_albedo.png"}]
        \\}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube_textured.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_textured_WoodMaterial.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "albedo = \"meshes/cube_albedo.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color = [1, 1, 1, 1]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_roughness = 1.000000") != null);
}

test "generateFromGltf writes material with no textures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{"materials":[{"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1],"metallicFactor":0.0,"roughnessFactor":1.0}}]}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/solid.gltf", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/solid_material_0.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "[textures]\n\n[params]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color = [1, 0, 0, 1]") != null);
}

test "generateFromGltf does not overwrite handwritten material" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/cube_textured_WoodMaterial.zamat", "hand written\n");

    var gltf = try Gltf.parse(
        \\{"materials":[{"name":"WoodMaterial","pbrMetallicRoughness":{}}]}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube_textured.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 0), count);
    try testing.expect(!fileExists(tmp.dir, testing.io, "generated/materials/cube_textured_WoodMaterial.zamat"));
}

test "generateFromGltf extracts embedded image bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"Mat","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"bufferView":0,"mimeType":"image/png","name":"albedo"}],
        \\  "bufferViews":[{"buffer":0,"byteOffset":1,"byteLength":3}]
        \\}
    , testing.allocator);
    defer gltf.deinit();

    const bin = [_]u8{ 0xaa, 1, 2, 3, 0xbb };
    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube.glb", &gltf.value, &.{&bin});
    try testing.expectEqual(@as(usize, 1), count);

    const tex = try readTestFile(testing.allocator, tmp.dir, "generated/textures/cube_albedo.png");
    defer testing.allocator.free(tex);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, tex);

    const mat = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_Mat.zamat");
    defer testing.allocator.free(mat);
    try testing.expect(std.mem.indexOf(u8, mat, "albedo = \"generated/textures/cube_albedo.png\"") != null);
}
