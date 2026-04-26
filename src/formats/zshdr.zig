const std = @import("std");

const constants = @import("../shared/constants.zig");
const cooked_shader = @import("../assets/cooked/shader.zig");

pub const MAGIC = constants.FORMAT_MAGIC.ZSHDR;
pub const ZSHDR_VERSION: u32 = 1;
pub const HEADER_SIZE: u32 = MAGIC.len // magic
+ @sizeOf(u32) // version
+ @sizeOf(u8) // shader stage
+ @sizeOf(u16) // variant name count
+ @sizeOf(u16) // include count
+ @sizeOf(u32); // permutation count

pub const ShaderStage = cooked_shader.ShaderStage;
pub const VariantKey = cooked_shader.VariantKey;
pub const CookedShader = cooked_shader.CookedShader;

pub const ZShader = struct {
    stage: ShaderStage,
    variant_names: []const []const u8,
    includes: []const []const u8,
    permutations: []Permutation,

    pub const Permutation = struct {
        key: VariantKey,
        source: []const u8,
    };

    pub fn baseSource(self: *const ZShader) ![]const u8 {
        return self.sourceFor(.base);
    }

    pub fn sourceFor(self: *const ZShader, key: VariantKey) ![]const u8 {
        for (self.permutations) |permutation| {
            if (permutation.key.bits == key.bits) {
                return permutation.source;
            }
        }
        return error.ShaderPermutationNotFound;
    }

    pub fn variantKey(self: *const ZShader, enabled_variants: []const []const u8) !VariantKey {
        var key = VariantKey.base;
        for (enabled_variants) |enabled| {
            const index = self.variantIndex(enabled) orelse return error.UnknownShaderVariant;
            key = key.with(index);
        }
        return key;
    }

    fn variantIndex(self: *const ZShader, name: []const u8) ?usize {
        for (self.variant_names, 0..) |variant_name, i| {
            if (std.mem.eql(u8, variant_name, name)) {
                return i;
            }
        }
        return null;
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !ZShader {
        var magic: [MAGIC.len]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) {
            return error.InvalidMagic;
        }

        const version = try reader.takeInt(u32, .little);
        if (version != ZSHDR_VERSION) {
            return error.UnsupportedVersion;
        }

        const stage: ShaderStage = @enumFromInt(try reader.takeInt(u8, .little));
        const variant_count = try reader.takeInt(u16, .little);
        const include_count = try reader.takeInt(u16, .little);
        const permutation_count = try reader.takeInt(u32, .little);

        const variant_names = try readStringList(allocator, reader, variant_count);
        errdefer freeStringList(allocator, variant_names);

        const includes = try readStringList(allocator, reader, include_count);
        errdefer freeStringList(allocator, includes);

        const permutations = try allocator.alloc(Permutation, permutation_count);
        errdefer allocator.free(permutations);

        var loaded: usize = 0;
        errdefer for (permutations[0..loaded]) |perm| allocator.free(perm.source);

        for (permutations) |*perm| {
            const key = VariantKey.fromBits(try reader.takeInt(u32, .little));
            const source_len = try reader.takeInt(u32, .little);
            const source = try allocator.alloc(u8, source_len);
            errdefer allocator.free(source);
            try reader.readSliceAll(source);
            perm.* = .{ .key = key, .source = source };
            loaded += 1;
        }

        return .{
            .stage = stage,
            .variant_names = variant_names,
            .includes = includes,
            .permutations = permutations,
        };
    }

    pub fn deinit(self: *ZShader, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.variant_names);
        freeStringList(allocator, self.includes);
        for (self.permutations) |perm| allocator.free(perm.source);
        allocator.free(self.permutations);
    }
};

pub fn write(writer: *std.Io.Writer, cooked: CookedShader) !void {
    try writer.writeAll(MAGIC);
    try writer.writeInt(u32, ZSHDR_VERSION, .little);
    try writer.writeInt(u8, @intFromEnum(cooked.stage), .little);
    try writer.writeInt(u16, @intCast(cooked.variant_names.len), .little);
    try writer.writeInt(u16, @intCast(cooked.includes.len), .little);
    try writer.writeInt(u32, @intCast(cooked.permutations.len), .little);

    for (cooked.variant_names) |name| {
        try writeString(writer, name);
    }
    for (cooked.includes) |include| {
        try writeString(writer, include);
    }

    for (cooked.permutations) |perm| {
        try writer.writeInt(u32, perm.key.bits, .little);
        try writer.writeInt(u32, @intCast(perm.source.len), .little);
        try writer.writeAll(perm.source);
    }
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeInt(u16, @intCast(value.len), .little);
    try writer.writeAll(value);
}

fn readStringList(allocator: std.mem.Allocator, reader: *std.Io.Reader, count: usize) ![]const []const u8 {
    const items = try allocator.alloc([]const u8, count);
    errdefer allocator.free(items);

    var loaded: usize = 0;
    errdefer for (items[0..loaded]) |item| allocator.free(item);

    for (items) |*item| {
        const len = try reader.takeInt(u16, .little);
        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);
        try reader.readSliceAll(bytes);
        item.* = bytes;
        loaded += 1;
    }

    return items;
}

fn dupeStringList(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(out);

    var loaded: usize = 0;
    errdefer for (out[0..loaded]) |item| allocator.free(item);

    for (strings, 0..) |value, i| {
        out[i] = try allocator.dupe(u8, value);
        loaded += 1;
    }

    return out;
}

fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

const testing = std.testing;

test "ZShader write and read round trips" {
    const variant_names = try dupeStringList(testing.allocator, &.{"SKINNED"});
    const includes = try dupeStringList(testing.allocator, &.{"common.glsl"});
    const permutations = try testing.allocator.alloc(CookedShader.Permutation, 1);
    permutations[0] = .{
        .key = .fromBits(1),
        .source = try testing.allocator.dupe(u8, "#version 330 core\n#define SKINNED\n"),
    };

    var cooked = CookedShader{
        .stage = .vertex,
        .variant_names = variant_names,
        .includes = includes,
        .permutations = permutations,
    };
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);

    var reader = std.Io.Reader.fixed(buf[0..writer.end]);
    var loaded = try ZShader.read(testing.allocator, &reader);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ShaderStage.vertex, loaded.stage);
    try testing.expectEqualStrings("SKINNED", loaded.variant_names[0]);
    try testing.expectEqualStrings("common.glsl", loaded.includes[0]);
    try testing.expectEqual(VariantKey.fromBits(1), loaded.permutations[0].key);
    try testing.expectEqualStrings("#version 330 core\n#define SKINNED\n", loaded.permutations[0].source);
    try testing.expectEqualStrings(loaded.permutations[0].source, try loaded.sourceFor(.fromBits(1)));
    try testing.expectEqual(VariantKey.fromBits(1), try loaded.variantKey(&.{"SKINNED"}));
}
