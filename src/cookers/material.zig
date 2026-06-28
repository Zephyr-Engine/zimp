const std = @import("std");

const Cooker = @import("cooker.zig").Cooker;
const file_read = @import("../shared/file_read.zig");
const raw_material = @import("../assets/raw/material.zig");
const raw_shader = @import("../assets/raw/shader.zig");
const CookedMaterial = @import("../assets/cooked/material.zig").CookedMaterial;
const slotNameToIndex = @import("../assets/cooked/material.zig").slotNameToIndex;
const zamat = @import("../formats/zamat.zig");
const log = @import("../logger.zig");

pub fn cooker() Cooker {
    return .{ .cookFn = cookMaterial, .asset_type = .material };
}

fn cookMaterial(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    var source = try raw_material.parseMaterialSource(file_result.bytes, allocator);
    defer source.deinit(allocator);

    try validateReferences(allocator, io, source_dir, file_path, &source);

    var cooked = try CookedMaterial.cook(allocator, &source);
    defer cooked.deinit(allocator);

    try zamat.write(writer, cooked);
}

fn validateReferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    source: *raw_material.MaterialSource,
) !void {
    const vert_path = try std.fmt.allocPrint(allocator, "{s}.vert", .{source.shader_path});
    defer allocator.free(vert_path);
    const frag_path = try std.fmt.allocPrint(allocator, "{s}.frag", .{source.shader_path});
    defer allocator.free(frag_path);

    if (!fileExists(source_dir, io, vert_path)) {
        log.err("{s}: shader '{s}' not found - missing {s}", .{ file_path, source.shader_path, vert_path });
        return error.MissingShader;
    }
    if (!fileExists(source_dir, io, frag_path)) {
        log.err("{s}: shader '{s}' not found - missing {s}", .{ file_path, source.shader_path, frag_path });
        return error.MissingShader;
    }

    var reflected = try reflectMaterialShaders(allocator, io, source_dir, vert_path, frag_path);
    defer reflected.deinit(allocator);

    for (source.textures) |slot| {
        if (!fileExists(source_dir, io, slot.texture_path)) {
            log.warn("{s}: texture '{s}' not found", .{ file_path, slot.texture_path });
        }
        if (slotNameToIndex(slot.slot_name) == null) {
            log.warn("{s}: unknown texture slot '{s}'", .{ file_path, slot.slot_name });
        }
        try validateTextureSlot(file_path, slot, &reflected);
    }

    for (source.params) |param| {
        try validateParam(file_path, param, &reflected);
    }

    try validateBindings(file_path, source);
    source.required_variants = try selectRequiredVariants(allocator, source, reflected.variants);
}

fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

const UniformKind = enum {
    sampler,
    float,
    vec2,
    vec3,
    vec4,
    int,
    bool,
    mat4,
    other,
};

const Uniform = struct {
    name: []const u8,
    kind: UniformKind,
};

const ReflectedShaders = struct {
    uniforms: []Uniform,
    variants: []const []const u8,

    fn deinit(self: *ReflectedShaders, allocator: std.mem.Allocator) void {
        for (self.uniforms) |uniform| allocator.free(uniform.name);
        allocator.free(self.uniforms);
        for (self.variants) |variant| allocator.free(variant);
        allocator.free(self.variants);
    }

    fn findUniform(self: *const ReflectedShaders, name: []const u8) ?Uniform {
        for (self.uniforms) |uniform| {
            if (std.mem.eql(u8, uniform.name, name)) return uniform;
        }
        return null;
    }

    fn hasVariant(self: *const ReflectedShaders, name: []const u8) bool {
        for (self.variants) |variant| {
            if (std.mem.eql(u8, variant, name)) return true;
        }
        return false;
    }
};

fn reflectMaterialShaders(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    vert_path: []const u8,
    frag_path: []const u8,
) !ReflectedShaders {
    var uniforms: std.ArrayList(Uniform) = .empty;
    errdefer {
        for (uniforms.items) |uniform| allocator.free(uniform.name);
        uniforms.deinit(allocator);
    }
    var variants: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (variants.items) |variant| allocator.free(variant);
        variants.deinit(allocator);
    }

    try reflectShaderFile(allocator, io, source_dir, vert_path, &uniforms, &variants);
    try reflectShaderFile(allocator, io, source_dir, frag_path, &uniforms, &variants);

    return .{
        .uniforms = try uniforms.toOwnedSlice(allocator),
        .variants = try variants.toOwnedSlice(allocator),
    };
}

fn reflectShaderFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    path: []const u8,
    uniforms: *std.ArrayList(Uniform),
    variants: *std.ArrayList([]const u8),
) !void {
    const file_result = try file_read.readFileAllocChunked(allocator, io, source_dir, path, .{
        .chunk_size = 256 * 1024,
    });
    defer allocator.free(file_result.bytes);

    var shader = try raw_shader.RawShader.init(allocator, io, source_dir, path, file_result.bytes);
    defer shader.deinit(allocator);

    for (shader.variants) |variant| {
        if (!containsString(variants.items, variant)) {
            try variants.append(allocator, try allocator.dupe(u8, variant));
        }
    }

    var lines = std.mem.splitScalar(u8, shader.source, '\n');
    while (lines.next()) |line| {
        try parseUniformLine(allocator, line, uniforms);
    }
}

fn parseUniformLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    uniforms: *std.ArrayList(Uniform),
) !void {
    const no_comment = if (std.mem.indexOf(u8, line, "//")) |idx| line[0..idx] else line;
    const trimmed = std.mem.trim(u8, no_comment, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "uniform ")) return;

    var it = std.mem.tokenizeAny(u8, trimmed, " \t;");
    _ = it.next() orelse return;
    const type_name = it.next() orelse return;
    var uniform_name = it.next() orelse return;
    if (std.mem.indexOfScalar(u8, uniform_name, '[')) |idx| {
        uniform_name = uniform_name[0..idx];
    }

    if (findUniformInList(uniforms.items, uniform_name) != null) return;

    try uniforms.append(allocator, .{
        .name = try allocator.dupe(u8, uniform_name),
        .kind = uniformKind(type_name),
    });
}

fn uniformKind(type_name: []const u8) UniformKind {
    if (std.mem.startsWith(u8, type_name, "sampler")) return .sampler;
    if (std.mem.eql(u8, type_name, "float")) return .float;
    if (std.mem.eql(u8, type_name, "vec2")) return .vec2;
    if (std.mem.eql(u8, type_name, "vec3")) return .vec3;
    if (std.mem.eql(u8, type_name, "vec4")) return .vec4;
    if (std.mem.eql(u8, type_name, "int")) return .int;
    if (std.mem.eql(u8, type_name, "bool")) return .bool;
    if (std.mem.eql(u8, type_name, "mat4")) return .mat4;
    return .other;
}

fn validateTextureSlot(file_path: []const u8, slot: raw_material.TextureSlot, reflected: *const ReflectedShaders) !void {
    if (textureUniformName(slot.slot_name)) |uniform_name| {
        const uniform = reflected.findUniform(uniform_name) orelse {
            log.err("{s}: texture slot '{s}' expects shader sampler uniform '{s}'", .{ file_path, slot.slot_name, uniform_name });
            return error.MissingShaderUniform;
        };
        if (uniform.kind != .sampler) {
            log.err("{s}: texture slot '{s}' uniform '{s}' is not a sampler", .{ file_path, slot.slot_name, uniform_name });
            return error.ShaderUniformTypeMismatch;
        }
    }
}

fn validateParam(file_path: []const u8, param: raw_material.ParamValue, reflected: *const ReflectedShaders) !void {
    const uniform = reflected.findUniform(param.name) orelse {
        log.err("{s}: material param '{s}' has no matching shader uniform", .{ file_path, param.name });
        return error.MissingShaderUniform;
    };
    const expected = paramUniformKind(param.value);
    if (uniform.kind != expected) {
        log.err("{s}: material param '{s}' type does not match shader uniform", .{ file_path, param.name });
        return error.ShaderUniformTypeMismatch;
    }
}

fn validateBindings(file_path: []const u8, source: *const raw_material.MaterialSource) !void {
    for (source.textures, 0..) |a, i| {
        for (source.textures[i + 1 ..]) |b| {
            if (a.shader_set == b.shader_set and a.shader_binding == b.shader_binding) {
                log.err("{s}: duplicate texture binding set={d} binding={d}", .{ file_path, a.shader_set, a.shader_binding });
                return error.DuplicateShaderBinding;
            }
        }
    }
    for (source.params, 0..) |a, i| {
        for (source.params[i + 1 ..]) |b| {
            if (a.shader_set == b.shader_set and a.shader_binding == b.shader_binding) {
                log.err("{s}: duplicate param binding set={d} binding={d}", .{ file_path, a.shader_set, a.shader_binding });
                return error.DuplicateShaderBinding;
            }
        }
    }
    for (source.textures) |texture| {
        for (source.params) |param| {
            if (texture.shader_set == param.shader_set and texture.shader_binding == param.shader_binding) {
                log.err("{s}: duplicate texture/param binding set={d} binding={d}", .{ file_path, texture.shader_set, texture.shader_binding });
                return error.DuplicateShaderBinding;
            }
        }
    }
}

fn selectRequiredVariants(
    allocator: std.mem.Allocator,
    source: *const raw_material.MaterialSource,
    declared_variants: []const []const u8,
) ![]const []const u8 {
    var selected: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (selected.items) |variant| allocator.free(variant);
        selected.deinit(allocator);
    }

    const candidates = [_]struct { name: []const u8, enabled: bool }{
        .{ .name = "HAS_ALBEDO_MAP", .enabled = hasTexture(source, "albedo") },
        .{ .name = "HAS_NORMAL_MAP", .enabled = hasTexture(source, "normal") },
        .{ .name = "HAS_AO", .enabled = hasTexture(source, "ao") or hasTexture(source, "orm") },
        .{ .name = "HAS_EMISSIVE", .enabled = hasTexture(source, "emissive") },
        .{ .name = "HAS_METALLIC_ROUGHNESS_MAP", .enabled = hasTexture(source, "roughness_metallic") or hasTexture(source, "orm") },
        .{ .name = "ALPHA_TEST", .enabled = source.render_state.alpha_mode == .alpha_test },
        .{ .name = "ALPHA_BLEND", .enabled = source.render_state.alpha_mode == .alpha_blend },
        .{ .name = "DOUBLE_SIDED", .enabled = source.render_state.double_sided },
    };

    for (candidates) |candidate| {
        if (!candidate.enabled) continue;
        if (!containsString(declared_variants, candidate.name)) continue;
        try selected.append(allocator, try allocator.dupe(u8, candidate.name));
    }

    return selected.toOwnedSlice(allocator);
}

fn textureUniformName(slot_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, slot_name, "albedo")) return "u_albedo";
    if (std.mem.eql(u8, slot_name, "normal")) return "u_normal_map";
    if (std.mem.eql(u8, slot_name, "roughness")) return "u_roughness_map";
    if (std.mem.eql(u8, slot_name, "metallic")) return "u_metallic_map";
    if (std.mem.eql(u8, slot_name, "ao")) return "u_ao_map";
    if (std.mem.eql(u8, slot_name, "emissive")) return "u_emissive_map";
    if (std.mem.eql(u8, slot_name, "roughness_metallic")) return "u_roughness_metallic_map";
    if (std.mem.eql(u8, slot_name, "orm")) return "u_orm_map";
    return null;
}

fn paramUniformKind(value: raw_material.ParamValue.Value) UniformKind {
    return switch (value) {
        .float => .float,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .vec4 => .vec4,
        .int => .int,
        .bool => .bool,
    };
}

fn hasTexture(source: *const raw_material.MaterialSource, slot_name: []const u8) bool {
    for (source.textures) |slot| {
        if (std.mem.eql(u8, slot.slot_name, slot_name)) return true;
    }
    return false;
}

fn containsString(strings: []const []const u8, needle: []const u8) bool {
    for (strings) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn findUniformInList(uniforms: []const Uniform, name: []const u8) ?Uniform {
    for (uniforms) |uniform| {
        if (std.mem.eql(u8, uniform.name, name)) return uniform;
    }
    return null;
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

test "material cooker writes zamat" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.albedo]
        \\path = "textures/missing.png"
        \\[param.u_roughness]
        \\value = 0.5
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\uniform sampler2D u_albedo;
        \\uniform float u_roughness;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);

    try testing.expectEqualSlices(u8, zamat.MAGIC, out[0..zamat.MAGIC.len]);
}

test "material cooker errors on missing shader" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/missing"
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.MissingShader, cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker rejects params missing from shader reflection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[param.u_missing]
        \\value = 0.5
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag", "void main() {}\n");

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.MissingShaderUniform, cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker rejects param type mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[param.u_roughness]
        \\value = [1.0, 2.0]
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\uniform float u_roughness;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.ShaderUniformTypeMismatch, cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker rejects texture and param binding collision" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.albedo]
        \\path = "textures/missing.png"
        \\set = 0
        \\binding = 0
        \\[param.u_base_color]
        \\value = [1.0, 1.0, 1.0, 1.0]
        \\set = 0
        \\binding = 0
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\uniform sampler2D u_albedo;
        \\uniform vec4 u_base_color;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.DuplicateShaderBinding, cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker selects declared variants from material contents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[render_state]
        \\alpha_mode = "alpha_test"
        \\[texture.normal]
        \\path = "textures/missing.png"
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\#version 330 core
        \\// VARIANTS: HAS_NORMAL_MAP, ALPHA_TEST
        \\uniform sampler2D u_normal_map;
        \\void main() {}
        \\
    );

    var out: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterial(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);

    var reader = std.Io.Reader.fixed(out[0..writer.end]);
    var loaded = try zamat.Zamat.read(testing.allocator, &reader);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), loaded.required_variants.len);
    try testing.expectEqualStrings("HAS_NORMAL_MAP", loaded.required_variants[0]);
    try testing.expectEqualStrings("ALPHA_TEST", loaded.required_variants[1]);
}
