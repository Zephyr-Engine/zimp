const std = @import("std");

const asset = @import("asset.zig");
const Cooker = @import("../cookers/cooker.zig").Cooker;
const DependencyExtractor = @import("../extractors/extractor.zig").DependencyExtractor;
const SourceFile = @import("source_file.zig").SourceFile;

const AssetType = asset.AssetType;
const Extension = asset.Extension;

const glb_cooker = @import("../cookers/glb.zig").cooker();
const gltf_cooker = @import("../cookers/gltf.zig").cooker();
const obj_cooker = @import("../cookers/obj.zig").cooker();
const tex_cooker = @import("../cookers/tex.zig").cooker();
const shader_cooker = @import("../cookers/shader.zig").cooker();
const material_cooker = @import("../cookers/material.zig").cooker();

const mesh_extractor = @import("../extractors/mesh.zig").extractor();
const shader_extractor = @import("../extractors/shader.zig").extractor();
const material_extractor = @import("../extractors/material.zig").extractor();

pub const AssetDescriptor = struct {
    extension: Extension,
    asset_type: AssetType,
    cooker: ?Cooker = null,
    extractor: ?DependencyExtractor = null,

    pub fn isCookable(self: AssetDescriptor) bool {
        return self.cooker != null;
    }

    pub fn isDependencyOnly(self: AssetDescriptor) bool {
        return self.asset_type != .unknown and self.cooker == null;
    }
};

pub const descriptors = std.EnumArray(Extension, AssetDescriptor).init(.{
    .gltf = .{ .extension = .gltf, .asset_type = .mesh, .cooker = gltf_cooker, .extractor = mesh_extractor },
    .glb = .{ .extension = .glb, .asset_type = .mesh, .cooker = glb_cooker, .extractor = mesh_extractor },
    .obj = .{ .extension = .obj, .asset_type = .mesh, .cooker = obj_cooker, .extractor = mesh_extractor },
    .bin = .{ .extension = .bin, .asset_type = .unknown },
    .png = .{ .extension = .png, .asset_type = .texture, .cooker = tex_cooker },
    .jpg = .{ .extension = .jpg, .asset_type = .texture, .cooker = tex_cooker },
    .jpeg = .{ .extension = .jpeg, .asset_type = .texture, .cooker = tex_cooker },
    .hdr = .{ .extension = .hdr, .asset_type = .texture, .cooker = tex_cooker },
    .vert = .{ .extension = .vert, .asset_type = .shader, .cooker = shader_cooker, .extractor = shader_extractor },
    .frag = .{ .extension = .frag, .asset_type = .shader, .cooker = shader_cooker, .extractor = shader_extractor },
    .comp = .{ .extension = .comp, .asset_type = .shader, .cooker = shader_cooker, .extractor = shader_extractor },
    .glsl = .{ .extension = .glsl, .asset_type = .shader, .extractor = shader_extractor },
    .zamat = .{ .extension = .zamat, .asset_type = .material, .cooker = material_cooker, .extractor = material_extractor },
    .other = .{ .extension = .other, .asset_type = .unknown },
});

comptime {
    for (std.meta.fields(Extension)) |field| {
        const ext: Extension = @enumFromInt(field.value);
        const descriptor = descriptors.get(ext);
        if (descriptor.extension != ext) {
            @compileError("AssetDescriptor extension field does not match key '" ++ field.name ++ "'");
        }
        if (descriptor.asset_type != ext.assetType()) {
            @compileError("AssetDescriptor for extension '" ++ field.name ++ "' has asset_type that does not match asset.zig mapping");
        }
        if (descriptor.cooker) |cooker| {
            if (cooker.asset_type != descriptor.asset_type) {
                @compileError("Cooker for extension '" ++ field.name ++ "' has asset_type that does not match descriptor");
            }
        }
        if (descriptor.extractor) |extractor| {
            if (extractor.asset_type != descriptor.asset_type) {
                @compileError("DependencyExtractor for extension '" ++ field.name ++ "' has asset_type that does not match descriptor");
            }
        }
    }
}

pub fn descriptorForExtension(extension: Extension) AssetDescriptor {
    return descriptors.get(extension);
}

pub fn descriptorForSource(source: SourceFile) AssetDescriptor {
    return descriptorForExtension(source.extension);
}

pub fn cookerFor(extension: Extension) ?Cooker {
    return descriptorForExtension(extension).cooker;
}

pub fn extractDependencies(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    if (descriptorForSource(source.*).extractor) |extractor| {
        return extractor.extract(source, dir, io, allocator);
    }
    return &.{};
}

const testing = std.testing;

test "descriptors match extension asset type mapping" {
    for (std.enums.values(Extension)) |ext| {
        const descriptor = descriptorForExtension(ext);
        try testing.expectEqual(ext, descriptor.extension);
        try testing.expectEqual(ext.assetType(), descriptor.asset_type);
    }
}

test "cookable and dependency-only descriptors are explicit" {
    try testing.expect(descriptorForExtension(.glb).isCookable());
    try testing.expect(descriptorForExtension(.png).isCookable());
    try testing.expect(!descriptorForExtension(.glsl).isCookable());
    try testing.expect(descriptorForExtension(.glsl).isDependencyOnly());
    try testing.expect(!descriptorForExtension(.other).isDependencyOnly());
}

test "shader cooker output path preserves shader stage extension" {
    const c = cookerFor(.vert).?;
    const path = try c.outputPath(testing.allocator, "shaders/basic.vert");
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("shaders/basic.vert.zshdr", path);
}

test "default cooker output path uses source stem" {
    const c = cookerFor(.glb).?;
    const path = try c.outputPath(testing.allocator, "meshes/triangle.glb");
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("meshes/triangle.zmesh", path);
}

test "glb and gltf keep distinct cookers" {
    const glb = cookerFor(.glb).?;
    const gltf = cookerFor(.gltf).?;
    try testing.expect(glb.cook_fn != gltf.cook_fn);
}

test "extractDependencies returns empty slice for texture and unknown assets" {
    const texture = SourceFile{ .path = "a.png", .extension = .png };
    const texture_deps = try extractDependencies(&texture, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(texture_deps);
    try testing.expectEqual(@as(usize, 0), texture_deps.len);

    const unknown = SourceFile{ .path = "a.xyz", .extension = .other };
    const unknown_deps = try extractDependencies(&unknown, std.Io.Dir.cwd(), testing.io, testing.allocator);
    defer testing.allocator.free(unknown_deps);
    try testing.expectEqual(@as(usize, 0), unknown_deps.len);
}

test "extractDependencies routes shader stages and glsl includes through shader extractor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "a.vert", .{});
    file.close(testing.io);
    const include_file = try tmp.dir.createFile(testing.io, "common.glsl", .{});
    include_file.close(testing.io);

    const shader = SourceFile{ .path = "a.vert", .extension = .vert };
    const shader_deps = try extractDependencies(&shader, tmp.dir, testing.io, testing.allocator);
    defer testing.allocator.free(shader_deps);
    try testing.expectEqual(@as(usize, 0), shader_deps.len);

    const include = SourceFile{ .path = "common.glsl", .extension = .glsl };
    const include_deps = try extractDependencies(&include, tmp.dir, testing.io, testing.allocator);
    defer testing.allocator.free(include_deps);
    try testing.expectEqual(@as(usize, 0), include_deps.len);
}
