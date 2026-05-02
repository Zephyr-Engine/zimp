const std = @import("std");

const source_file = @import("../source_file.zig");
const raw_material = @import("../raw/material.zig");

pub const AlphaMode = raw_material.AlphaMode;
pub const Hash = source_file.Hash;

pub const TextureSlotIndex = enum(u16) {
    albedo = 0,
    normal = 1,
    roughness = 2,
    metallic = 3,
    ao = 4,
    emissive = 5,
    roughness_metallic = 6,
    orm = 7,
};

pub fn slotNameToIndex(name: []const u8) ?TextureSlotIndex {
    if (std.mem.eql(u8, name, "albedo")) return .albedo;
    if (std.mem.eql(u8, name, "normal")) return .normal;
    if (std.mem.eql(u8, name, "roughness")) return .roughness;
    if (std.mem.eql(u8, name, "metallic")) return .metallic;
    if (std.mem.eql(u8, name, "ao")) return .ao;
    if (std.mem.eql(u8, name, "emissive")) return .emissive;
    if (std.mem.eql(u8, name, "roughness_metallic")) return .roughness_metallic;
    if (std.mem.eql(u8, name, "orm")) return .orm;
    return null;
}

pub const ParamType = enum(u16) {
    float = 0,
    vec2 = 1,
    vec3 = 2,
    vec4 = 3,
    int = 4,
    bool = 5,
};

pub const TextureSlotEntry = struct {
    slot_name_hash: Hash,
    texture_path_hash: Hash,
    slot_index: u16,
};

pub const ParamEntry = struct {
    name_hash: Hash,
    param_type: ParamType,
    data_offset: u16,
    data_size: u16,
};

pub const ParamBuildResult = struct {
    entries: []ParamEntry,
    data: []u8,

    pub fn deinit(self: *ParamBuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.data);
    }
};

pub const CookedMaterial = struct {
    shader_path_hash: Hash,
    alpha_mode: AlphaMode,
    texture_slots: []TextureSlotEntry,
    param_entries: []ParamEntry,
    param_data: []u8,

    pub fn cook(allocator: std.mem.Allocator, source: *const raw_material.MaterialSource) !CookedMaterial {
        const texture_slots = try allocator.alloc(TextureSlotEntry, source.textures.len);
        errdefer allocator.free(texture_slots);

        for (source.textures, texture_slots) |slot, *entry| {
            entry.* = .{
                .slot_name_hash = source_file.fnv1a(slot.slot_name),
                .texture_path_hash = source_file.fnv1a(slot.texture_path),
                .slot_index = if (slotNameToIndex(slot.slot_name)) |idx| @intFromEnum(idx) else std.math.maxInt(u16),
            };
        }

        var params = try buildParamDataBlock(source.params, allocator);
        errdefer params.deinit(allocator);

        return .{
            .shader_path_hash = source_file.fnv1a(source.shader_path),
            .alpha_mode = source.alpha_mode,
            .texture_slots = texture_slots,
            .param_entries = params.entries,
            .param_data = params.data,
        };
    }

    pub fn deinit(self: *CookedMaterial, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_slots);
        allocator.free(self.param_entries);
        allocator.free(self.param_data);
    }
};

pub fn buildParamDataBlock(params: []const raw_material.ParamValue, allocator: std.mem.Allocator) !ParamBuildResult {
    var entries = try std.ArrayList(ParamEntry).initCapacity(allocator, params.len);
    errdefer entries.deinit(allocator);

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);

    for (params) |param| {
        if (data.items.len > std.math.maxInt(u16)) return error.ParamDataTooLarge;
        const data_offset: u16 = @intCast(data.items.len);
        const before = data.items.len;
        const param_type = try appendParamBytes(&data, allocator, param.value);
        const size = data.items.len - before;
        if (size > std.math.maxInt(u16)) return error.ParamDataTooLarge;

        entries.appendAssumeCapacity(.{
            .name_hash = source_file.fnv1a(param.name),
            .param_type = param_type,
            .data_offset = data_offset,
            .data_size = @intCast(size),
        });
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .data = try data.toOwnedSlice(allocator),
    };
}

fn appendParamBytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: raw_material.ParamValue.Value) !ParamType {
    switch (value) {
        .float => |v| {
            try appendF32(list, allocator, v);
            return .float;
        },
        .vec2 => |v| {
            for (v) |component| try appendF32(list, allocator, component);
            return .vec2;
        },
        .vec3 => |v| {
            for (v) |component| try appendF32(list, allocator, component);
            return .vec3;
        },
        .vec4 => |v| {
            for (v) |component| try appendF32(list, allocator, component);
            return .vec4;
        },
        .int => |v| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(i32, &bytes, v, .little);
            try list.appendSlice(allocator, &bytes);
            return .int;
        },
        .bool => |v| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, if (v) 1 else 0, .little);
            try list.appendSlice(allocator, &bytes);
            return .bool;
        },
    }
}

fn appendF32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
    try list.appendSlice(allocator, &bytes);
}

const testing = std.testing;

test "slotNameToIndex maps known slots" {
    try testing.expectEqual(TextureSlotIndex.albedo, slotNameToIndex("albedo").?);
    try testing.expectEqual(TextureSlotIndex.normal, slotNameToIndex("normal").?);
    try testing.expectEqual(@as(?TextureSlotIndex, null), slotNameToIndex("unknown_custom"));
}

test "buildParamDataBlock packs params and offsets" {
    const params = [_]raw_material.ParamValue{
        .{ .name = "u_roughness", .value = .{ .float = 0.5 } },
        .{ .name = "u_uv_scale", .value = .{ .vec2 = .{ 2.0, 2.0 } } },
    };

    var result = try buildParamDataBlock(&params, testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.entries.len);
    try testing.expectEqual(@as(usize, 12), result.data.len);
    try testing.expectEqual(@as(u16, 0), result.entries[0].data_offset);
    try testing.expectEqual(@as(u16, 4), result.entries[1].data_offset);
    try testing.expectEqual(ParamType.float, result.entries[0].param_type);
    try testing.expectEqual(ParamType.vec2, result.entries[1].param_type);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.5))), std.mem.readInt(u32, result.data[0..4], .little));
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 2.0))), std.mem.readInt(u32, result.data[4..8], .little));
}
