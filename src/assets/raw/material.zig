const std = @import("std");

pub const AlphaMode = enum(u16) {
    solid = 0,
    alpha_test = 1,
    alpha_blend = 2,
};

pub const TextureSlot = struct {
    slot_name: []const u8,
    texture_path: []const u8,
};

pub const ParamValue = struct {
    name: []const u8,
    value: Value,

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
    alpha_mode: AlphaMode = .solid,
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
    }
};

const Section = enum {
    material,
    textures,
    params,
};

pub fn parseMaterialSource(source: []const u8, allocator: std.mem.Allocator) !MaterialSource {
    var shader_path: ?[]const u8 = null;
    errdefer if (shader_path) |path| allocator.free(path);

    var alpha_mode: AlphaMode = .solid;

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

    var section: ?Section = null;
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
                .material
            else if (std.mem.eql(u8, name, "textures"))
                .textures
            else if (std.mem.eql(u8, name, "params"))
                .params
            else
                return error.UnknownMaterialSection;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.ExpectedEquals;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidKeyValue;

        switch (section orelse return error.KeyOutsideSection) {
            .material => {
                if (std.mem.eql(u8, key, "shader")) {
                    if (shader_path) |old| allocator.free(old);
                    shader_path = try allocator.dupe(u8, try parseQuoted(value));
                } else if (std.mem.eql(u8, key, "alpha_mode")) {
                    alpha_mode = try parseAlphaMode(try parseQuoted(value));
                } else {
                    return error.UnknownMaterialKey;
                }
            },
            .textures => {
                const slot_name = try allocator.dupe(u8, key);
                errdefer allocator.free(slot_name);
                const texture_path = try allocator.dupe(u8, try parseQuoted(value));
                errdefer allocator.free(texture_path);
                try textures.append(allocator, .{
                    .slot_name = slot_name,
                    .texture_path = texture_path,
                });
            },
            .params => {
                const name = try allocator.dupe(u8, key);
                errdefer allocator.free(name);
                const parsed_value = try parseParamValue(value);
                try params.append(allocator, .{
                    .name = name,
                    .value = parsed_value,
                });
            },
        }
    }

    return .{
        .shader_path = shader_path orelse return error.MissingShaderPath,
        .alpha_mode = alpha_mode,
        .textures = try textures.toOwnedSlice(allocator),
        .params = try params.toOwnedSlice(allocator),
    };
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

test "parseMaterialSource parses material section and default alpha" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("shaders/basic", source.shader_path);
    try testing.expectEqual(AlphaMode.solid, source.alpha_mode);
}

test "parseMaterialSource parses alpha blend" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\alpha_mode = "alpha_blend"
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqual(AlphaMode.alpha_blend, source.alpha_mode);
}

test "parseMaterialSource collects texture slots in order" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[textures]
        \\albedo = "textures/brick_albedo.png"
        \\normal = "textures/sub/brick_normal.png"
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
        \\[params]
        \\u_roughness  =  0.5
        \\u_mode = 2
        \\u_enabled = true
        \\u_uv_scale = [2.0, 2.0]
        \\u_light_dir = [0.5, 1.0, 0.3]
        \\u_base_color = [1.0, 1.0, 1.0, 1.0]
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
        \\[params]
        \\u_bad = [1.0]
        \\
    , testing.allocator));
}

test "parseMaterialSource parses full example" {
    var source = try parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
        \\[textures]
        \\albedo = "textures/test_albedo.png"
        \\normal = "textures/test_normal.png"
        \\
        \\[params]
        \\u_roughness = 0.5
        \\u_light_dir = [0.5, 1.0, 0.3]
        \\u_light_color = [1.0, 0.95, 0.9]
        \\
    , testing.allocator);
    defer source.deinit(testing.allocator);

    try testing.expectEqualStrings("shaders/basic", source.shader_path);
    try testing.expectEqual(@as(usize, 2), source.textures.len);
    try testing.expectEqual(@as(usize, 3), source.params.len);
    try testing.expectEqual(AlphaMode.solid, source.alpha_mode);
}
