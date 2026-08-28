const std = @import("std");

const asset = @import("asset.zig");
const Cooker = @import("../cookers/cooker.zig").Cooker;
const DependencyExtractor = @import("../extractors/extractor.zig").DependencyExtractor;
const SourceFile = @import("source_file.zig").SourceFile;

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
    cooker: ?Cooker = null,
    extractor: ?DependencyExtractor = null,

    pub fn isCookable(self: AssetDescriptor) bool {
        return self.cooker != null;
    }

    pub fn isDependencyOnly(self: AssetDescriptor) bool {
        return self.extractor != null and self.cooker == null;
    }
};

pub const descriptors = std.EnumArray(Extension, AssetDescriptor).init(.{
    .gltf = .{ .cooker = gltf_cooker, .extractor = mesh_extractor },
    .glb = .{ .cooker = glb_cooker, .extractor = mesh_extractor },
    .obj = .{ .cooker = obj_cooker, .extractor = mesh_extractor },
    .bin = .{},
    .png = .{ .cooker = tex_cooker },
    .jpg = .{ .cooker = tex_cooker },
    .jpeg = .{ .cooker = tex_cooker },
    .hdr = .{ .cooker = tex_cooker },
    .vert = .{ .cooker = shader_cooker, .extractor = shader_extractor },
    .frag = .{ .cooker = shader_cooker, .extractor = shader_extractor },
    .comp = .{ .cooker = shader_cooker, .extractor = shader_extractor },
    .glsl = .{ .extractor = shader_extractor },
    .zamat = .{ .cooker = material_cooker, .extractor = material_extractor },
    .other = .{},
});

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

test "cookable and dependency-only descriptors are explicit" {
    try testing.expect(descriptorForExtension(.glb).isCookable());
    try testing.expect(descriptorForExtension(.png).isCookable());
    try testing.expect(!descriptorForExtension(.glsl).isCookable());
    try testing.expect(descriptorForExtension(.glsl).isDependencyOnly());
    try testing.expect(!descriptorForExtension(.other).isDependencyOnly());
}

test "shader cooker output path preserves shader stage extension" {
    const c = cookerFor(.vert).?;
    const path = try c.outputPath(testing.allocator, SourceFile.fromPath("shaders/basic.vert"));
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("shaders/basic.vert.zshdr", path);
}

test "default cooker output path uses source stem" {
    const c = cookerFor(.glb).?;
    const path = try c.outputPath(testing.allocator, SourceFile.fromPath("meshes/triangle.glb"));
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
