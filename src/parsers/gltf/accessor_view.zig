const std = @import("std");

pub const AccessorView = struct {
    bytes: []const u8,
    start: usize,
    stride: usize,
    element_size: usize,
    count: usize,
    component_type: u32,
    component_count: usize,
    normalized: bool,

    pub fn element(self: AccessorView, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        const at = self.start + index * self.stride;
        return self.bytes[at..][0..self.element_size];
    }

    pub fn readIndex(self: AccessorView, index: usize) !u32 {
        if (self.component_count != 1 or self.normalized) {
            return error.InvalidAccessorType;
        }

        const bytes = self.element(index);
        return switch (self.component_type) {
            5121 => bytes[0],
            5123 => std.mem.readInt(u16, bytes[0..2], .little),
            5125 => std.mem.readInt(u32, bytes[0..4], .little),
            else => error.InvalidAccessorType,
        };
    }

    pub fn readVec2(self: AccessorView, index: usize) ![2]f32 {
        if (self.component_count != 2) {
            return error.InvalidAccessorType;
        }
        return .{ try self.readFloatComponent(index, 0), try self.readFloatComponent(index, 1) };
    }

    pub fn readVec3(self: AccessorView, index: usize) ![3]f32 {
        if (self.component_count != 3) {
            return error.InvalidAccessorType;
        }
        return .{ try self.readFloatComponent(index, 0), try self.readFloatComponent(index, 1), try self.readFloatComponent(index, 2) };
    }

    pub fn readVec4(self: AccessorView, index: usize) ![4]f32 {
        if (self.component_count != 4) {
            return error.InvalidAccessorType;
        }
        return .{
            try self.readFloatComponent(index, 0),
            try self.readFloatComponent(index, 1),
            try self.readFloatComponent(index, 2),
            try self.readFloatComponent(index, 3),
        };
    }

    pub fn readU16Vec4(self: AccessorView, index: usize) ![4]u16 {
        if (self.component_count != 4 or self.normalized) {
            return error.InvalidAccessorType;
        }
        var result: [4]u16 = undefined;
        for (0..4) |component| result[component] = try self.readUnsignedU16(index, component);
        return result;
    }

    fn readFloatComponent(self: AccessorView, index: usize, component: usize) !f32 {
        const bytes = self.componentBytes(index, component);
        return switch (self.component_type) {
            5126 => @bitCast(std.mem.readInt(u32, bytes[0..4], .little)),
            5120 => normalizeSigned(i8, @bitCast(bytes[0]), self.normalized),
            5121 => normalizeUnsigned(u8, bytes[0], self.normalized),
            5122 => normalizeSigned(i16, @bitCast(std.mem.readInt(u16, bytes[0..2], .little)), self.normalized),
            5123 => normalizeUnsigned(u16, std.mem.readInt(u16, bytes[0..2], .little), self.normalized),
            5125 => normalizeUnsigned(u32, std.mem.readInt(u32, bytes[0..4], .little), self.normalized),
            else => error.InvalidAccessorType,
        };
    }

    fn readUnsignedU16(self: AccessorView, index: usize, component: usize) !u16 {
        const bytes = self.componentBytes(index, component);
        return switch (self.component_type) {
            5121 => bytes[0],
            5123 => std.mem.readInt(u16, bytes[0..2], .little),
            else => error.InvalidAccessorType,
        };
    }

    fn componentBytes(self: AccessorView, index: usize, component: usize) []const u8 {
        std.debug.assert(component < self.component_count);
        const component_size = self.element_size / self.component_count;
        const bytes = self.element(index);
        return bytes[component * component_size ..][0..component_size];
    }
};

fn normalizeUnsigned(comptime T: type, value: T, normalized: bool) f32 {
    const value_f: f32 = @floatFromInt(value);
    return if (normalized) value_f / @as(f32, @floatFromInt(std.math.maxInt(T))) else value_f;
}

fn normalizeSigned(comptime T: type, value: T, normalized: bool) f32 {
    const value_f: f32 = @floatFromInt(value);
    return if (normalized) @max(-1.0, value_f / @as(f32, @floatFromInt(std.math.maxInt(T)))) else value_f;
}
