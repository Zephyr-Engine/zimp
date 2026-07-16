const std = @import("std");
const uuid_mod = @import("uuid.zig");
const Uuid = uuid_mod.Uuid;

/// Distinct nominal wrapper around `Uuid` for one identity domain. Each
/// enum-literal tag instantiates a separate type, so the compiler rejects
/// passing an `AssetId` where a `SceneEntityId` is expected. The JSON wire
/// text is identical to a bare `Uuid` (canonical lowercase string), so
/// persisted formats are unaffected by the wrapper.
fn TypedId(comptime tag: @TypeOf(.enum_literal)) type {
    return struct {
        uuid: Uuid,

        const Self = @This();

        /// Domain name for diagnostics and error messages.
        pub const id_domain = @tagName(tag);

        pub const zero: Self = .{ .uuid = Uuid.zero };

        pub fn v4(random: std.Random) Self {
            return .{ .uuid = Uuid.v4(random) };
        }

        pub fn fromUuid(u: Uuid) Self {
            return .{ .uuid = u };
        }

        pub fn fromBytes(bytes: [16]u8) Self {
            return .{ .uuid = Uuid.fromBytes(bytes) };
        }

        pub fn derive(namespace: Uuid, name: []const u8) Self {
            return .{ .uuid = Uuid.deriveV8(namespace, name) };
        }

        pub fn parse(text: []const u8) uuid_mod.ParseError!Self {
            return .{ .uuid = try Uuid.parse(text) };
        }

        pub fn parseComptime(comptime text: []const u8) Self {
            return .{ .uuid = Uuid.parseComptime(text) };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.uuid.eql(other.uuid);
        }

        pub fn isZero(self: Self) bool {
            return self.uuid.isZero();
        }

        pub fn toString(self: Self) [36]u8 {
            return self.uuid.toString();
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return .{ .uuid = try Uuid.jsonParse(allocator, source, options) };
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Self {
            return .{ .uuid = try Uuid.jsonParseFromValue(allocator, source, options) };
        }

        pub fn jsonStringify(self: Self, writer: anytype) !void {
            try self.uuid.jsonStringify(writer);
        }
    };
}

pub const ComponentTypeId = TypedId(.component_type);
pub const SceneEntityId = TypedId(.scene_entity);
pub const ProjectId = TypedId(.project);
pub const SchemaId = TypedId(.schema);
pub const AssetId = TypedId(.asset);
pub const SceneId = TypedId(.scene);

const testing = std.testing;

test "typed ids are distinct nominal types" {
    comptime std.debug.assert(AssetId != SceneId);
    comptime std.debug.assert(SceneEntityId != SceneId);
    comptime std.debug.assert(ProjectId != SchemaId);
    // The same tag yields the same type everywhere (generic memoization).
    comptime std.debug.assert(AssetId == TypedId(.asset));
}

test "typed id forwards Uuid operations" {
    var prng = std.Random.DefaultPrng.init(0);
    const a = AssetId.v4(prng.random());
    try testing.expect(!a.isZero());
    try testing.expect(a.eql(a));
    try testing.expect(AssetId.zero.isZero());

    const parsed = try AssetId.parse("12345678-9abc-4def-8012-3456789abcde");
    try testing.expectEqualStrings("12345678-9abc-4def-8012-3456789abcde", &parsed.toString());

    const fixed = AssetId.parseComptime("12345678-9abc-4def-8012-3456789abcde");
    try testing.expect(parsed.eql(fixed));

    const ns = Uuid.parseComptime("7a0e3d4c-915b-4f27-8c1d-6602b3f4a910");
    const derived = AssetId.derive(ns, "generated/materials/golden.zamat");
    try testing.expectEqualStrings("cde59dc1-afbd-8740-b00d-adee8cb339ce", &derived.toString());
}

test "typed id JSON wire text matches bare Uuid" {
    const raw = Uuid.parseComptime("12345678-9abc-4def-8012-3456789abcde");
    const id = AssetId.fromUuid(raw);

    const id_json = try std.json.Stringify.valueAlloc(testing.allocator, id, .{});
    defer testing.allocator.free(id_json);
    const raw_json = try std.json.Stringify.valueAlloc(testing.allocator, raw, .{});
    defer testing.allocator.free(raw_json);
    try testing.expectEqualStrings(raw_json, id_json);

    const parsed = try std.json.parseFromSlice(AssetId, testing.allocator, id_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.eql(id));
}

test "typed id works as an AutoHashMap key" {
    var prng = std.Random.DefaultPrng.init(7);
    var map = std.AutoHashMap(AssetId, u32).init(testing.allocator);
    defer map.deinit();

    const a = AssetId.v4(prng.random());
    const b = AssetId.v4(prng.random());
    try map.put(a, 1);
    try map.put(b, 2);
    try testing.expectEqual(@as(?u32, 1), map.get(a));
    try testing.expectEqual(@as(?u32, 2), map.get(b));
    try testing.expectEqual(@as(?u32, null), map.get(AssetId.zero));
}
