const std = @import("std");

const model = @import("../manifest/model.zig");

pub const PublishedAsset = struct {
    manifest_entry: model.AssetManifestEntry,
    owned_cooked_path: []const u8,

    fn deinit(self: *PublishedAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.owned_cooked_path);
    }
};

pub const PublishedAssets = struct {
    items: []PublishedAsset,

    pub fn deinit(self: *PublishedAssets, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
    }
};
