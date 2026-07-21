const std = @import("std");

const id_types = @import("../id/id_types.zig");
const Uuid = @import("../id/uuid.zig").Uuid;
const value = @import("value.zig");

pub const SceneDocument = struct {
    format: []const u8 = "zephyr.scene",
    version: u32 = 1,
    scene_id: id_types.SceneId,
    project_id: id_types.ProjectId,
    name: []const u8,
    schema_hash: u64 = 0,
    asset_manifest_hash: u64 = 0,
    active_camera: ?id_types.SceneEntityId = null,
    entities: []SceneEntity,

    pub fn deinit(self: *SceneDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.format);
        allocator.free(self.name);

        for (self.entities) |*entity| {
            allocator.free(entity.name);

            for (entity.components) |*component| {
                for (component.fields) |*field| {
                    field.value.deinit(allocator);
                }
                allocator.free(component.fields);
            }
            allocator.free(entity.components);
        }
        allocator.free(self.entities);
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
