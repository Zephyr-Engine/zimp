const std = @import("std");

const id_types = @import("../id/id_types.zig");
const Uuid = @import("../id/uuid.zig").Uuid;
const value = @import("value.zig");

pub const SceneDocument = struct {
    /// All document-owned data, including decoded strings and nested arrays.
    arena: std.heap.ArenaAllocator,
    format: []const u8,
    version: u32,
    scene_id: id_types.SceneId,
    project_id: id_types.ProjectId,
    name: []const u8,
    schema_hash: u64 = 0,
    asset_manifest_hash: u64 = 0,
    active_camera: ?id_types.SceneEntityId = null,
    entities: []SceneEntity,

    pub fn init(
        allocator: std.mem.Allocator,
        scene_id: id_types.SceneId,
        project_id: id_types.ProjectId,
        name: []const u8,
    ) !SceneDocument {
        const arena = std.heap.ArenaAllocator.init(allocator);
        var self = SceneDocument{
            .arena = arena,
            .format = undefined,
            .version = 1,
            .scene_id = scene_id,
            .project_id = project_id,
            .name = undefined,
            .entities = &.{},
        };
        errdefer self.arena.deinit();

        const storage = self.arena.allocator();
        self.format = try storage.dupe(u8, "zephyr.scene");
        self.name = try storage.dupe(u8, name);

        return self;
    }

    pub fn deinit(self: *SceneDocument) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SceneEntity = struct {
    id: id_types.SceneEntityId,
    parent_id: ?id_types.SceneEntityId = null,
    name: []const u8,
    components: []SceneComponent,
    prefab: PrefabInstanceMetadata,
};

pub const SceneComponent = struct {
    type_id: id_types.ComponentTypeId,
    version: u32 = 1,
    fields: []value.SceneField,

    pub fn asData(self: *const SceneComponent) value.SceneComponentData {
        return .{ .component = self.type_id, .fields = self.fields };
    }
};

pub const PrefabInstanceMetadata = struct {
    prefab_asset: ?id_types.AssetId = null,
    source_entity: ?id_types.SceneEntityId = null,
    override_set_id: ?Uuid = null,
};
