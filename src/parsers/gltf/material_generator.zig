const std = @import("std");

const resolveRelativeUri = @import("document.zig").resolveRelativeUri;
const GltfTextureInfo = @import("gltf_json_parser.zig").GltfTextureInfo;
const AtomicFile = @import("../../shared/atomic_file.zig").AtomicFile;
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const GltfMaterial = @import("gltf_json_parser.zig").GltfMaterial;
const GltfSampler = @import("gltf_json_parser.zig").GltfSampler;
const Extension = @import("../../assets/asset.zig").Extension;
const GltfDocument = @import("document.zig").GltfDocument;
const GltfJson = @import("gltf_json_parser.zig").GltfJson;
const GltfPbr = @import("gltf_json_parser.zig").GltfPbr;
const raw_material = @import("../../assets/raw/material.zig");
const file_read = @import("../../shared/file_read.zig");
const builtin = @import("../../builtin/registry.zig");
const GLBFile = @import("glb_parser.zig").GLBFile;
const Gltf = @import("gltf_json_parser.zig").Gltf;
const log = @import("../../logger.zig");

const DEFAULT_SHADER = builtin.PREFIX ++ "standard";
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
        if (source.extension != .glb and source.extension != .gltf and source.extension != .obj) {
            continue;
        }

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
        .obj => return generateDefaultMaterial(allocator, io, source_dir, file_path),
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
    if (gltf.materials.len == 0) {
        return generateDefaultMaterial(allocator, io, source_dir, source_path);
    }

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

        if (file_read.fileExists(source_dir, io, hand_path)) {
            continue;
        }

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try writeMaterialText(
            &text,
            allocator,
            io,
            source_dir,
            source_path,
            gltf,
            buffers,
            material,
            material_name,
        );

        if (try fileMatches(source_dir, io, allocator, output_path, text.items)) {
            continue;
        }

        var pending = try AtomicFile.create(allocator, io, source_dir, output_path);
        defer pending.deinit();
        var buf: [4096]u8 = undefined;
        var writer = pending.file.writer(io, &buf);
        try writer.interface.writeAll(text.items);
        try writer.interface.flush();
        try pending.commit();

        generated += 1;
        log.debug("Generated material '{s}' from '{s}'", .{ output_path, source_path });
    }

    return generated;
}

pub fn resolveMaterialPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
    gltf: *const GltfJson,
) ![][]u8 {
    const count = @max(gltf.materials.len, 1);
    const paths = try allocator.alloc([]u8, count);
    errdefer allocator.free(paths);
    var initialized: usize = 0;
    errdefer for (paths[0..initialized]) |path| allocator.free(path);

    for (0..count) |i| {
        const material_name = if (gltf.materials.len == 0)
            "DefaultMaterial"
        else
            gltf.materials[i].name orelse try std.fmt.allocPrint(allocator, "material_{d}", .{i});
        const allocated_name = gltf.materials.len != 0 and gltf.materials[i].name == null;
        defer if (allocated_name) allocator.free(material_name);

        const generated_path = try generatedMaterialPath(allocator, source_path, material_name);
        const handwritten_path = try handwrittenMaterialPath(allocator, std.fs.path.basename(generated_path));
        if (file_read.fileExists(source_dir, io, handwritten_path)) {
            allocator.free(generated_path);
            paths[i] = handwritten_path;
        } else {
            allocator.free(handwritten_path);
            paths[i] = generated_path;
        }
        initialized += 1;
    }
    return paths;
}

pub fn resolveDefaultMaterialPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
) ![]u8 {
    const empty: GltfJson = .{};
    const paths = try resolveMaterialPaths(allocator, io, source_dir, source_path, &empty);
    defer allocator.free(paths);
    return paths[0];
}

pub fn freeMaterialPaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn generateDefaultMaterial(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source_path: []const u8,
) !usize {
    try source_dir.createDirPath(io, GENERATED_MATERIAL_DIR);

    const output_path = try generatedMaterialPath(allocator, source_path, "DefaultMaterial");
    defer allocator.free(output_path);
    const hand_path = try handwrittenMaterialPath(allocator, std.fs.path.basename(output_path));
    defer allocator.free(hand_path);
    if (file_read.fileExists(source_dir, io, hand_path)) return 0;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const empty: GltfJson = .{};
    try writeMaterialText(&text, allocator, io, source_dir, source_path, &empty, &.{}, .{
        .name = "DefaultMaterial",
        .pbrMetallicRoughness = .{},
    }, "DefaultMaterial");
    if (try fileMatches(source_dir, io, allocator, output_path, text.items)) return 0;

    var pending = try AtomicFile.create(allocator, io, source_dir, output_path);
    defer pending.deinit();
    var buf: [4096]u8 = undefined;
    var writer = pending.file.writer(io, &buf);
    try writer.interface.writeAll(text.items);
    try writer.interface.flush();
    try pending.commit();
    log.debug("Generated default material '{s}' from '{s}'", .{ output_path, source_path });
    return 1;
}

fn fileMatches(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const result = file_read.readFileAllocChunked(allocator, io, dir, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer allocator.free(result.bytes);
    return std.mem.eql(u8, result.bytes, bytes);
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
        \\
        \\[render_state]
        \\alpha_mode = "{s}"
        \\alpha_cutoff = {d}
        \\double_sided = {s}
        \\cull_mode = "{s}"
        \\depth_test = true
        \\depth_write = {s}
        \\blend_mode = "{s}"
        \\
    , .{
        source_path,
        material_name,
        DEFAULT_SHADER,
        mapAlphaMode(material.alphaMode),
        material.alphaCutoff,
        if (material.doubleSided) "true" else "false",
        if (material.doubleSided) "none" else "back",
        if (isAlphaBlend(material.alphaMode)) "false" else "true",
        mapBlendMode(material.alphaMode),
    });

    if (material.pbrMetallicRoughness) |pbr| {
        if (pbr.baseColorTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "u_albedo", info, .{});
        if (pbr.metallicRoughnessTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "u_roughness_metallic_map", info, .{});
    }
    if (material.normalTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "u_normal_map", info, .{ .normal_scale = info.scale orelse 1.0 });
    if (material.occlusionTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "u_ao_map", info, .{ .occlusion_strength = info.strength orelse 1.0 });
    if (material.emissiveTexture) |info| try appendTexture(text, allocator, io, source_dir, source_path, gltf, buffers, "u_emissive_map", info, .{});

    const pbr = material.pbrMetallicRoughness orelse GltfPbr{};
    try text.appendSlice(allocator, "\n[params]\n");
    try appendParamVec4(text, allocator, "u_base_color", pbr.baseColorFactor);
    try appendParamFloat(text, allocator, "u_metallic", pbr.metallicFactor);
    try appendParamFloat(text, allocator, "u_roughness", pbr.roughnessFactor);
    try appendParamVec3(text, allocator, "u_emissive", material.emissiveFactor orelse .{ 0, 0, 0 });
}

const TextureOptions = struct {
    normal_scale: f32 = 1.0,
    occlusion_strength: f32 = 1.0,
};

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
    options: TextureOptions,
) !void {
    const path = try texturePath(allocator, io, source_dir, source_path, gltf, buffers, info.index);
    defer allocator.free(path);
    const sampler = samplerForTexture(gltf, info.index);
    try appendPrint(text, allocator,
        \\
        \\[texture.{s}]
        \\path = "{s}"
        \\uv_set = {d}
        \\uv_offset = [0, 0]
        \\uv_scale = [1, 1]
        \\uv_rotation = 0
        \\min_filter = "{s}"
        \\mag_filter = "{s}"
        \\mip_filter = "{s}"
        \\wrap_s = "{s}"
        \\wrap_t = "{s}"
        \\max_anisotropy = 1
        \\normal_scale = {d}
        \\occlusion_strength = {d}
        \\
    , .{
        slot_name,
        path,
        info.texCoord,
        minFilterName(sampler.minFilter),
        magFilterName(sampler.magFilter),
        mipFilterName(sampler.minFilter),
        wrapName(sampler.wrapS),
        wrapName(sampler.wrapT),
        options.normal_scale,
        options.occlusion_strength,
    });
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
    if (!file_read.fileExists(source_dir, io, path)) {
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

fn mapBlendMode(value: ?[]const u8) []const u8 {
    const mode = value orelse return "disabled";
    if (std.ascii.eqlIgnoreCase(mode, "BLEND")) return "alpha";
    return "disabled";
}

fn isAlphaBlend(value: ?[]const u8) bool {
    const mode = value orelse return false;
    return std.ascii.eqlIgnoreCase(mode, "BLEND");
}

fn appendParamFloat(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: f32) !void {
    try appendPrint(text, allocator, "{s} = {d:.6}\n", .{ name, value });
}

fn appendParamVec3(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: [3]f32) !void {
    try appendPrint(text, allocator, "{s} = [{d}, {d}, {d}]\n", .{ name, value[0], value[1], value[2] });
}

fn appendParamVec4(text: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: [4]f32) !void {
    try appendPrint(text, allocator, "{s} = [{d}, {d}, {d}, {d}]\n", .{ name, value[0], value[1], value[2], value[3] });
}

fn samplerForTexture(gltf: *const GltfJson, texture_index: u32) GltfSampler {
    if (texture_index >= gltf.textures.len) return .{};
    const sampler_index = gltf.textures[texture_index].sampler orelse return .{};
    if (sampler_index >= gltf.samplers.len) return .{};
    return gltf.samplers[sampler_index];
}

fn minFilterName(value: ?u32) []const u8 {
    return switch (value orelse 9987) {
        9728, 9984, 9986 => "nearest",
        else => "linear",
    };
}

fn magFilterName(value: ?u32) []const u8 {
    return switch (value orelse 9729) {
        9728 => "nearest",
        else => "linear",
    };
}

fn mipFilterName(value: ?u32) []const u8 {
    return switch (value orelse 9987) {
        9728, 9729 => "none",
        9984, 9985 => "nearest",
        else => "linear",
    };
}

fn wrapName(value: u32) []const u8 {
    return switch (value) {
        33071 => "clamp_to_edge",
        33648 => "mirrored_repeat",
        else => "repeat",
    };
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
        \\  "materials":[{"name":"WoodMaterial","alphaMode":"MASK","alphaCutoff":0.33,"doubleSided":true,"pbrMetallicRoughness":{"baseColorTexture":{"index":0,"texCoord":1},"baseColorFactor":[1,1,1,1],"metallicFactor":0.0,"roughnessFactor":1.0}}],
        \\  "textures":[{"source":0,"sampler":0}],
        \\  "samplers":[{"magFilter":9728,"minFilter":9984,"wrapS":33071,"wrapT":33648}],
        \\  "images":[{"uri":"cube_albedo.png"}]
        \\}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube_textured.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_textured_WoodMaterial.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "alpha_mode = \"alpha_test\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "alpha_cutoff = 0.33") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "double_sided = true") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "cull_mode = \"none\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[texture.u_albedo]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "path = \"meshes/cube_albedo.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "uv_set = 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "min_filter = \"nearest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "mag_filter = \"nearest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "mip_filter = \"nearest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "wrap_s = \"clamp_to_edge\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "wrap_t = \"mirrored_repeat\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[params]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color =") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_roughness =") != null);

    var parsed = try raw_material.parseMaterialSource(bytes, testing.allocator);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), parsed.params.len);
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
    try testing.expect(std.mem.indexOf(u8, bytes, "[render_state]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[texture.") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[params]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "u_base_color = [1, 0, 0, 1]") != null);
}

test "generateFromGltf creates a default slot material when gltf has no materials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gltf: GltfJson = .{};
    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/plain.gltf", &gltf, &.{});
    try testing.expectEqual(@as(usize, 1), count);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/plain_DefaultMaterial.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "shader = \"zephyr/standard\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[params]") != null);
}

test "resolveMaterialPaths preserves gltf order and selects handwritten overrides" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "materials/model_Second.zamat", "[material]\n");

    const materials = [_]GltfMaterial{
        .{ .name = "First" },
        .{ .name = "Second" },
    };
    const gltf: GltfJson = .{ .materials = @constCast(&materials) };
    const paths = try resolveMaterialPaths(testing.allocator, testing.io, tmp.dir, "meshes/model.glb", &gltf);
    defer freeMaterialPaths(testing.allocator, paths);

    try testing.expectEqualStrings("generated/materials/model_First.zamat", paths[0]);
    try testing.expectEqualStrings("materials/model_Second.zamat", paths[1]);
}

test "generateForSource creates a default material for obj" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const count = try generateForSource(testing.allocator, testing.io, tmp.dir, "meshes/monkey.obj", .obj);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(file_read.fileExists(tmp.dir, testing.io, "generated/materials/monkey_DefaultMaterial.zamat"));
}

test "generateFromGltf disables depth writes for blended materials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{"materials":[{"name":"Glass","alphaMode":"BLEND","pbrMetallicRoughness":{"baseColorFactor":[1,1,1,0.5]}}]}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/glass.gltf", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count);

    const bytes = try readTestFile(testing.allocator, tmp.dir, "generated/materials/glass_Glass.zamat");
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "alpha_mode = \"alpha_blend\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "depth_write = false") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "blend_mode = \"alpha\"") != null);
}

test "generateFromGltf preserves occlusion texture strength" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gltf = try Gltf.parse(
        \\{
        \\  "materials":[{"name":"Mat","occlusionTexture":{"index":0,"strength":0.25}}],
        \\  "textures":[{"source":0}],
        \\  "images":[{"uri":"ao.png"}]
        \\}
    , testing.allocator);
    defer gltf.deinit();

    const count = try generateFromGltf(testing.allocator, testing.io, tmp.dir, "meshes/cube.glb", &gltf.value, &.{});
    try testing.expectEqual(@as(usize, 1), count);

    const mat = try readTestFile(testing.allocator, tmp.dir, "generated/materials/cube_Mat.zamat");
    defer testing.allocator.free(mat);
    try testing.expect(std.mem.indexOf(u8, mat, "[texture.u_ao_map]") != null);
    try testing.expect(std.mem.indexOf(u8, mat, "occlusion_strength = 0.25") != null);
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
    try testing.expect(!file_read.fileExists(tmp.dir, testing.io, "generated/materials/cube_textured_WoodMaterial.zamat"));
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
    try testing.expect(std.mem.indexOf(u8, mat, "[texture.u_albedo]") != null);
    try testing.expect(std.mem.indexOf(u8, mat, "path = \"generated/textures/cube_albedo.png\"") != null);
}
