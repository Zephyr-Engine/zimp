const std = @import("std");

pub const AlphaMode = enum(u16) {
    solid = 0,
    alpha_test = 1,
    alpha_blend = 2,
};

pub const CullMode = enum(u16) {
    none = 0,
    front = 1,
    back = 2,
};

pub const BlendMode = enum(u16) {
    disabled = 0,
    alpha = 1,
    premultiplied_alpha = 2,
};

pub const FilterMode = enum(u8) {
    nearest = 0,
    linear = 1,
};

pub const MipFilterMode = enum(u8) {
    none = 0,
    nearest = 1,
    linear = 2,
};

pub const WrapMode = enum(u8) {
    repeat = 0,
    clamp_to_edge = 1,
    mirrored_repeat = 2,
};

pub const SamplerDesc = struct {
    min_filter: FilterMode = .linear,
    mag_filter: FilterMode = .linear,
    mip_filter: MipFilterMode = .linear,
    wrap_s: WrapMode = .repeat,
    wrap_t: WrapMode = .repeat,
    max_anisotropy: f32 = 1.0,
};

pub const RenderState = struct {
    alpha_mode: AlphaMode = .solid,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    cull_mode: CullMode = .back,
    depth_test: bool = true,
    depth_write: bool = true,
    blend_mode: BlendMode = .disabled,
};

pub const TextureSlot = struct {
    slot_name: []const u8,
    texture_path: []const u8,
    shader_set: u16 = 0,
    shader_binding: u16 = 0,
    uv_set: u16 = 0,
    uv_offset: [2]f32 = .{ 0, 0 },
    uv_scale: [2]f32 = .{ 1, 1 },
    uv_rotation: f32 = 0,
    sampler: SamplerDesc = .{},
    normal_scale: f32 = 1.0,
    occlusion_strength: f32 = 1.0,
};

pub const ParamValue = struct {
    name: []const u8,
    value: Value,
    shader_set: u16 = 1,
    shader_binding: u16 = 0,

    pub const Value = union(enum) {
        float: f32,
        vec2: [2]f32,
        vec3: [3]f32,
        vec4: [4]f32,
        int: i32,
        bool: bool,
    };
};

pub const MaterialSource = struct {
    shader_path: []const u8,
    render_state: RenderState = .{},
    required_variants: []const []const u8 = &.{},
    textures: []const TextureSlot,
    params: []const ParamValue,

    pub fn deinit(self: *MaterialSource, allocator: std.mem.Allocator) void {
        allocator.free(self.shader_path);
        for (self.textures) |slot| {
            allocator.free(slot.slot_name);
            allocator.free(slot.texture_path);
        }
        allocator.free(self.textures);
        for (self.params) |param| {
            allocator.free(param.name);
        }
        allocator.free(self.params);
        for (self.required_variants) |variant| allocator.free(variant);
        if (self.required_variants.len > 0) allocator.free(self.required_variants);
    }
};

const Section = enum {
    material,
    render_state,
    texture,
    param,
};

const ActiveSection = struct {
    kind: Section,
    name: ?[]const u8 = null,
};

pub fn parseMaterialSource(source: []const u8, allocator: std.mem.Allocator) !MaterialSource {
    var shader_path: ?[]const u8 = null;
    errdefer if (shader_path) |path| allocator.free(path);

    var render_state: RenderState = .{};

    var textures: std.ArrayList(TextureSlot) = .empty;
    errdefer {
        for (textures.items) |slot| {
            allocator.free(slot.slot_name);
            allocator.free(slot.texture_path);
        }
        textures.deinit(allocator);
    }

    var params: std.ArrayList(ParamValue) = .empty;
    errdefer {
        for (params.items) |param| allocator.free(param.name);
        params.deinit(allocator);
    }

    var section: ?ActiveSection = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t");
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = std.mem.trim(u8, line, " \t");

        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidSectionHeader;
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            section = if (std.mem.eql(u8, name, "material"))
                .{ .kind = .material }
            else if (std.mem.eql(u8, name, "render_state"))
                .{ .kind = .render_state }
            else if (std.mem.startsWith(u8, name, "texture."))
                .{ .kind = .texture, .name = name["texture.".len..] }
            else if (std.mem.startsWith(u8, name, "param."))
                .{ .kind = .param, .name = name["param.".len..] }
            else
                return error.UnknownMaterialSection;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.ExpectedEquals;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidKeyValue;

        const active = section orelse return error.KeyOutsideSection;
        switch (active.kind) {
            .material => {
                if (std.mem.eql(u8, key, "shader")) {
                    if (shader_path) |old| allocator.free(old);
                    shader_path = try allocator.dupe(u8, try parseQuoted(value));
                } else {
                    return error.UnknownMaterialKey;
                }
            },
            .render_state => try parseRenderStateKey(&render_state, key, value),
            .texture => {
                const name = active.name orelse return error.InvalidSectionHeader;
                try parseTextureSubsection(allocator, &textures, name, key, value);
            },
            .param => {
                const name = active.name orelse return error.InvalidSectionHeader;
                try parseParamSubsection(allocator, &params, name, key, value);
            },
        }
    }

    for (textures.items) |slot| {
        if (slot.texture_path.len == 0) return error.MissingTexturePath;
    }

    return .{
        .shader_path = shader_path orelse return error.MissingShaderPath,
        .render_state = render_state,
        .required_variants = &.{},
        .textures = try textures.toOwnedSlice(allocator),
        .params = try params.toOwnedSlice(allocator),
    };
}

fn parseRenderStateKey(state: *RenderState, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "alpha_mode")) {
        state.alpha_mode = try parseAlphaMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "alpha_cutoff")) {
        state.alpha_cutoff = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, key, "double_sided")) {
        state.double_sided = try parseBool(value);
        state.cull_mode = if (state.double_sided) .none else .back;
    } else if (std.mem.eql(u8, key, "cull_mode")) {
        state.cull_mode = try parseCullMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "depth_test")) {
        state.depth_test = try parseBool(value);
    } else if (std.mem.eql(u8, key, "depth_write")) {
        state.depth_write = try parseBool(value);
    } else if (std.mem.eql(u8, key, "blend_mode")) {
        state.blend_mode = try parseBlendMode(try parseQuoted(value));
    } else {
        return error.UnknownRenderStateKey;
    }
}

fn parseTextureSubsection(
    allocator: std.mem.Allocator,
    textures: *std.ArrayList(TextureSlot),
    slot_name_raw: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const index = try findOrAppendTexture(allocator, textures, slot_name_raw);
    var slot = &textures.items[index];
    if (std.mem.eql(u8, key, "path")) {
        allocator.free(slot.texture_path);
        slot.texture_path = try allocator.dupe(u8, try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "set")) {
        slot.shader_set = try parseU16(value);
    } else if (std.mem.eql(u8, key, "binding")) {
        slot.shader_binding = try parseU16(value);
    } else if (std.mem.eql(u8, key, "uv_set")) {
        slot.uv_set = try parseU16(value);
    } else if (std.mem.eql(u8, key, "uv_offset")) {
        slot.uv_offset = try parseVec2(value);
    } else if (std.mem.eql(u8, key, "uv_scale")) {
        slot.uv_scale = try parseVec2(value);
    } else if (std.mem.eql(u8, key, "uv_rotation")) {
        slot.uv_rotation = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, key, "min_filter")) {
        slot.sampler.min_filter = try parseFilterMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "mag_filter")) {
        slot.sampler.mag_filter = try parseFilterMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "mip_filter")) {
        slot.sampler.mip_filter = try parseMipFilterMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "wrap_s")) {
        slot.sampler.wrap_s = try parseWrapMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "wrap_t")) {
        slot.sampler.wrap_t = try parseWrapMode(try parseQuoted(value));
    } else if (std.mem.eql(u8, key, "max_anisotropy")) {
        slot.sampler.max_anisotropy = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, key, "normal_scale")) {
        slot.normal_scale = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, key, "occlusion_strength")) {
        slot.occlusion_strength = try std.fmt.parseFloat(f32, value);
    } else {
        return error.UnknownTextureKey;
    }
}

fn parseParamSubsection(
    allocator: std.mem.Allocator,
    params: *std.ArrayList(ParamValue),
    param_name_raw: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const index = try findOrAppendParam(allocator, params, param_name_raw);
    var param = &params.items[index];
    if (std.mem.eql(u8, key, "value")) {
        param.value = try parseParamValue(value);
    } else if (std.mem.eql(u8, key, "set")) {
        param.shader_set = try parseU16(value);
    } else if (std.mem.eql(u8, key, "binding")) {
        param.shader_binding = try parseU16(value);
    } else {
        return error.UnknownParamKey;
    }
}

fn findOrAppendTexture(allocator: std.mem.Allocator, textures: *std.ArrayList(TextureSlot), slot_name_raw: []const u8) !usize {
    for (textures.items, 0..) |slot, i| {
        if (std.mem.eql(u8, slot.slot_name, slot_name_raw)) return i;
    }
    const slot_name = try allocator.dupe(u8, slot_name_raw);
    errdefer allocator.free(slot_name);
    const texture_path = try allocator.dupe(u8, "");
    errdefer allocator.free(texture_path);
    try textures.append(allocator, .{
        .slot_name = slot_name,
        .texture_path = texture_path,
        .shader_binding = defaultTextureBinding(slot_name),
    });
    return textures.items.len - 1;
}

fn findOrAppendParam(allocator: std.mem.Allocator, params: *std.ArrayList(ParamValue), param_name_raw: []const u8) !usize {
    for (params.items, 0..) |param, i| {
        if (std.mem.eql(u8, param.name, param_name_raw)) return i;
    }
    const name = try allocator.dupe(u8, param_name_raw);
    errdefer allocator.free(name);
    try params.append(allocator, .{
        .name = name,
        .value = .{ .float = 0 },
        .shader_binding = @intCast(params.items.len),
    });
    return params.items.len - 1;
}

fn parseQuoted(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.ExpectedQuotedString;
    return value[1 .. value.len - 1];
}

pub fn parseAlphaMode(value: []const u8) !AlphaMode {
    if (std.mem.eql(u8, value, "solid")) return .solid;
    if (std.mem.eql(u8, value, "alpha_test")) return .alpha_test;
    if (std.mem.eql(u8, value, "alpha_blend")) return .alpha_blend;
    return error.UnknownAlphaMode;
}

fn parseCullMode(value: []const u8) !CullMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "front")) return .front;
    if (std.mem.eql(u8, value, "back")) return .back;
    return error.UnknownCullMode;
}

fn parseBlendMode(value: []const u8) !BlendMode {
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "alpha")) return .alpha;
    if (std.mem.eql(u8, value, "premultiplied_alpha")) return .premultiplied_alpha;
    return error.UnknownBlendMode;
}

fn parseFilterMode(value: []const u8) !FilterMode {
    if (std.mem.eql(u8, value, "nearest")) return .nearest;
    if (std.mem.eql(u8, value, "linear")) return .linear;
    return error.UnknownFilterMode;
}

fn parseMipFilterMode(value: []const u8) !MipFilterMode {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "nearest")) return .nearest;
    if (std.mem.eql(u8, value, "linear")) return .linear;
    return error.UnknownMipFilterMode;
}

fn parseWrapMode(value: []const u8) !WrapMode {
    if (std.mem.eql(u8, value, "repeat")) return .repeat;
    if (std.mem.eql(u8, value, "clamp_to_edge")) return .clamp_to_edge;
    if (std.mem.eql(u8, value, "mirrored_repeat")) return .mirrored_repeat;
    return error.UnknownWrapMode;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBool;
}

fn parseU16(value: []const u8) !u16 {
    return try std.fmt.parseInt(u16, value, 10);
}

fn parseVec2(value: []const u8) ![2]f32 {
    const parsed = try parseParamValue(value);
    return switch (parsed) {
        .vec2 => |v| v,
        else => error.InvalidParamValue,
    };
}

fn defaultTextureBinding(slot_name: []const u8) u16 {
    if (std.mem.eql(u8, slot_name, "albedo")) return 0;
    if (std.mem.eql(u8, slot_name, "normal")) return 1;
    if (std.mem.eql(u8, slot_name, "roughness")) return 2;
    if (std.mem.eql(u8, slot_name, "metallic")) return 3;
    if (std.mem.eql(u8, slot_name, "ao")) return 4;
    if (std.mem.eql(u8, slot_name, "emissive")) return 5;
    if (std.mem.eql(u8, slot_name, "roughness_metallic")) return 6;
    if (std.mem.eql(u8, slot_name, "orm")) return 7;
    return std.math.maxInt(u16);
}

fn parseParamValue(value: []const u8) !ParamValue.Value {
    if (std.mem.eql(u8, value, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, value, "false")) return .{ .bool = false };

    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        var values: [4]f32 = undefined;
        var count: usize = 0;
        var parts = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
        while (parts.next()) |part| {
            if (count == values.len) return error.UnsupportedParamArrayLength;
            const trimmed = std.mem.trim(u8, part, " \t\r");
            if (trimmed.len == 0) return error.InvalidParamValue;
            values[count] = try std.fmt.parseFloat(f32, trimmed);
            count += 1;
        }

        return switch (count) {
            2 => .{ .vec2 = .{ values[0], values[1] } },
            3 => .{ .vec3 = .{ values[0], values[1], values[2] } },
            4 => .{ .vec4 = .{ values[0], values[1], values[2], values[3] } },
            else => error.UnsupportedParamArrayLength,
        };
    }

    if (looksFloat(value)) {
        return .{ .float = try std.fmt.parseFloat(f32, value) };
    }

    return .{ .int = try std.fmt.parseInt(i32, value, 10) };
}

fn looksFloat(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, ".eE") != null;
}

const testing = std.testing;

test "parseMaterialSource parses material section" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("shaders/basic", source.shader_path);
    try testing.expectEqual(AlphaMode.solid, source.render_state.alpha_mode);
}

test "parseMaterialSource parses v2 render state texture and param subsections" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\
        \\[render_state]
        \\alpha_mode = "alpha_test"
        \\alpha_cutoff = 0.33
        \\double_sided = true
        \\depth_test = false
        \\depth_write = false
        \\blend_mode = "alpha"
        \\
        \\[texture.albedo]
        \\path = "textures/brick_albedo.png"
        \\set = 2
        \\binding = 3
        \\uv_set = 1
        \\uv_offset = [0.25, 0.5]
        \\uv_scale = [2.0, 3.0]
        \\uv_rotation = 0.75
        \\min_filter = "nearest"
        \\mag_filter = "linear"
        \\mip_filter = "nearest"
        \\wrap_s = "clamp_to_edge"
        \\wrap_t = "mirrored_repeat"
        \\max_anisotropy = 8
        \\
        \\[param.u_roughness]
        \\value = 0.65
        \\set = 4
        \\binding = 5
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqual(AlphaMode.alpha_test, source.render_state.alpha_mode);
    try testing.expectEqual(@as(f32, 0.33), source.render_state.alpha_cutoff);
    try testing.expect(source.render_state.double_sided);
    try testing.expectEqual(CullMode.none, source.render_state.cull_mode);
    try testing.expect(!source.render_state.depth_test);
    try testing.expect(!source.render_state.depth_write);
    try testing.expectEqual(BlendMode.alpha, source.render_state.blend_mode);

    try testing.expectEqual(@as(usize, 1), source.textures.len);
    const tex = source.textures[0];
    try testing.expectEqualStrings("albedo", tex.slot_name);
    try testing.expectEqualStrings("textures/brick_albedo.png", tex.texture_path);
    try testing.expectEqual(@as(u16, 2), tex.shader_set);
    try testing.expectEqual(@as(u16, 3), tex.shader_binding);
    try testing.expectEqual(@as(u16, 1), tex.uv_set);
    try testing.expectEqual([2]f32{ 0.25, 0.5 }, tex.uv_offset);
    try testing.expectEqual([2]f32{ 2.0, 3.0 }, tex.uv_scale);
    try testing.expectEqual(FilterMode.nearest, tex.sampler.min_filter);
    try testing.expectEqual(WrapMode.clamp_to_edge, tex.sampler.wrap_s);
    try testing.expectEqual(WrapMode.mirrored_repeat, tex.sampler.wrap_t);

    try testing.expectEqual(@as(usize, 1), source.params.len);
    try testing.expectEqualStrings("u_roughness", source.params[0].name);
    try testing.expectEqual(@as(f32, 0.65), source.params[0].value.float);
    try testing.expectEqual(@as(u16, 4), source.params[0].shader_set);
    try testing.expectEqual(@as(u16, 5), source.params[0].shader_binding);
}

test "parseMaterialSource rejects texture subsection without path" {
    try testing.expectError(error.MissingTexturePath, parseMaterialSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\[texture.albedo]
        \\binding = 0
        \\
    , testing.allocator));
}

test "parseMaterialSource rejects pre-v2 material forms" {
    try testing.expectError(error.UnknownMaterialKey, parseMaterialSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\alpha_mode = "alpha_test"
        \\
    , testing.allocator));

    try testing.expectError(error.UnknownMaterialSection, parseMaterialSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\[textures]
        \\albedo = "textures/brick_albedo.png"
        \\
    , testing.allocator));

    try testing.expectError(error.ExpectedQuotedString, parseMaterialSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\[render_state]
        \\alpha_mode = alpha_test
        \\
    , testing.allocator));

    try testing.expectError(error.UnknownBlendMode, parseMaterialSource(
        \\[material]
        \\shader = "shaders/pbr"
        \\[render_state]
        \\blend_mode = "opaque"
        \\
    , testing.allocator));
}

test "parseMaterialSource collects texture slots in order" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.albedo]
        \\path = "textures/brick_albedo.png"
        \\[texture.normal]
        \\path = "textures/sub/brick_normal.png"
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), source.textures.len);
    try testing.expectEqualStrings("albedo", source.textures[0].slot_name);
    try testing.expectEqualStrings("textures/brick_albedo.png", source.textures[0].texture_path);
    try testing.expectEqualStrings("normal", source.textures[1].slot_name);
    try testing.expectEqualStrings("textures/sub/brick_normal.png", source.textures[1].texture_path);
}

test "parseMaterialSource parses params" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[param.u_roughness]
        \\value = 0.5
        \\[param.u_mode]
        \\value = 2
        \\[param.u_enabled]
        \\value = true
        \\[param.u_uv_scale]
        \\value = [2.0, 2.0]
        \\[param.u_light_dir]
        \\value = [0.5, 1.0, 0.3]
        \\[param.u_base_color]
        \\value = [1.0, 1.0, 1.0, 1.0]
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), source.params.len);
    try testing.expectEqual(@as(f32, 0.5), source.params[0].value.float);
    try testing.expectEqual(@as(i32, 2), source.params[1].value.int);
    try testing.expect(source.params[2].value.bool);
    try testing.expectEqual(@as(f32, 2.0), source.params[3].value.vec2[0]);
    try testing.expectEqual(@as(f32, 0.3), source.params[4].value.vec3[2]);
    try testing.expectEqual(@as(f32, 1.0), source.params[5].value.vec4[3]);
}

test "parseMaterialSource rejects unsupported array lengths" {
    try testing.expectError(error.UnsupportedParamArrayLength, parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[param.u_bad]
        \\value = [1.0]
        \\
    , testing.allocator));
}

test "parseMaterialSource parses full example" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
        \\[texture.albedo]
        \\path = "textures/test_albedo.png"
        \\
        \\[texture.normal]
        \\path = "textures/test_normal.png"
        \\
        \\[param.u_roughness]
        \\value = 0.5
        \\
        \\[param.u_light_dir]
        \\value = [0.5, 1.0, 0.3]
        \\
        \\[param.u_light_color]
        \\value = [1.0, 0.95, 0.9]
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("shaders/basic", source.shader_path);
    try testing.expectEqual(@as(usize, 2), source.textures.len);
    try testing.expectEqual(@as(usize, 3), source.params.len);
    try testing.expectEqual(AlphaMode.solid, source.render_state.alpha_mode);
}
