const std = @import("std");

const raw_shader = @import("../raw/shader.zig");

pub const ShaderStage = raw_shader.ShaderStage;
pub const VariantKey = raw_shader.VariantKey;
pub const RawShader = raw_shader.RawShader;

pub const CookedShader = struct {
    stage: ShaderStage,
    variant_names: []const []const u8,
    includes: []const []const u8,
    permutations: []Permutation,

    pub const Permutation = struct {
        key: VariantKey,
        source: []const u8,
    };

    pub fn cook(allocator: std.mem.Allocator, raw: *const RawShader) !CookedShader {
        const variant_names = try dupeStringList(allocator, raw.variants);
        errdefer freeStringList(allocator, variant_names);

        const includes = try dupeStringList(allocator, raw.includes);
        errdefer freeStringList(allocator, includes);

        const keys = try raw_shader.generateVariantKeys(raw.variants.len, allocator);
        defer allocator.free(keys);

        const permutations = try allocator.alloc(Permutation, keys.len);
        errdefer allocator.free(permutations);

        var loaded: usize = 0;
        errdefer for (permutations[0..loaded]) |perm| allocator.free(perm.source);

        for (keys, 0..) |key, i| {
            permutations[i] = .{
                .key = key,
                .source = try raw_shader.makeVariantSource(allocator, raw.source, raw.variants, key),
            };
            loaded += 1;
        }

        return .{
            .stage = raw.stage,
            .variant_names = variant_names,
            .includes = includes,
            .permutations = permutations,
        };
    }

    pub fn deinit(self: *CookedShader, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.variant_names);
        freeStringList(allocator, self.includes);
        for (self.permutations) |perm| allocator.free(perm.source);
        allocator.free(self.permutations);
    }
};

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

test "CookedShader cook expands variants" {
    const variants = [_][]const u8{"SKINNED"};
    const raw = RawShader{
        .path = "basic.vert",
        .stage = .vertex,
        .source = "#version 330 core\n// VARIANTS: SKINNED\nvoid main() {}\n",
        .variants = &variants,
        .includes = &.{},
    };

    var cooked = try CookedShader.cook(testing.allocator, &raw);
    defer cooked.deinit(testing.allocator);

    try testing.expectEqual(ShaderStage.vertex, cooked.stage);
    try testing.expectEqual(@as(usize, 2), cooked.permutations.len);
    try testing.expectEqual(VariantKey.base, cooked.permutations[0].key);
    try testing.expectEqual(VariantKey.fromBits(1), cooked.permutations[1].key);
    try testing.expect(std.mem.indexOf(u8, cooked.permutations[1].source, "#define SKINNED") != null);
}
