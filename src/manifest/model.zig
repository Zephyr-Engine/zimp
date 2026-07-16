const std = @import("std");
const AssetId = @import("../id/id_types.zig").AssetId;
const ProjectId = @import("../id/id_types.zig").ProjectId;
const AssetKind = @import("kind.zig").AssetKind;
const errors = @import("errors.zig");
const path = @import("../path.zig");

pub const AssetManifestEntry = struct {
    id: AssetId,
    kind: AssetKind,
    /// Relative to the project assets dir, e.g. "meshes/monkey.glb".
    source_path: []const u8,
    /// Relative to the project cooked dir, e.g. "meshes/monkey.zmesh".
    cooked_path: []const u8,
    /// fnv1a of source contents (same Hash the cook cache uses).
    content_hash: u64,
    source_size: u64,
    cooked_size: u64,
    /// Source lives under generated/ (derived id, no sidecar).
    generated: bool = false,
};

/// The canonical in-memory manifest used by builder, codec, and tooling.
/// Arena-owned: every slice lives in `arena`. The runtime has its own
/// trimmed loader so builder code never links into the game.
pub const AssetManifest = struct {
    /// Owns every slice in the manifest.
    arena: std.heap.ArenaAllocator,
    project_id: ProjectId,
    /// Sorted by source_path (builder invariant, validated on load).
    entries: []AssetManifestEntry,

    pub fn deinit(self: *AssetManifest) void {
        self.arena.deinit();
    }

    /// Full semantic validation. Called by the codec after decode and by
    /// the builder before encode, so no invalid manifest can be written OR
    /// accepted.
    pub fn validate(self: *const AssetManifest) errors.ManifestError!void {
        var prev_source: ?[]const u8 = null;
        var seen_ids = std.AutoHashMap(AssetId, void).init(self.arena.child_allocator);
        defer seen_ids.deinit();
        seen_ids.ensureTotalCapacity(@intCast(self.entries.len)) catch return error.CorruptManifest;

        for (self.entries) |entry| {
            if (entry.id.isZero()) return error.ZeroAssetId;
            path.validateVirtual(entry.source_path) catch return error.InvalidAssetPath;
            path.validateVirtual(entry.cooked_path) catch return error.InvalidAssetPath;

            if (prev_source) |prev| {
                switch (std.mem.order(u8, prev, entry.source_path)) {
                    .lt => {},
                    .eq => return error.DuplicateSourcePath,
                    .gt => return error.CorruptManifest, // not sorted
                }
            }
            prev_source = entry.source_path;

            const gop = seen_ids.getOrPutAssumeCapacity(entry.id);
            if (gop.found_existing) return error.DuplicateAssetId;
        }
    }

    pub fn findBySourcePath(self: *const AssetManifest, source_path: []const u8) ?*const AssetManifestEntry {
        // entries sorted by source_path -> binary search
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].source_path, source_path)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return &self.entries[mid],
            }
        }
        return null;
    }
};

// ── Test fixtures (shared by codec/builder tests) ────────────────────────

pub const TestEntrySpec = struct {
    id: []const u8, // canonical uuid string
    kind: AssetKind = .mesh,
    source_path: []const u8,
    cooked_path: []const u8 = "cooked.bin",
    content_hash: u64 = 0,
    generated: bool = false,
};

pub const test_project_id = ProjectId.parseComptime("b0d5c1f2-88a1-4a5e-9f2d-77aa01c3e9b4");

/// Build a fixture manifest for tests. Entries are used in the order given
/// (deliberately NOT sorted here, so tests can construct invalid manifests).
pub fn testManifest(gpa: std.mem.Allocator, entry_specs: []const TestEntrySpec) !AssetManifest {
    var m = AssetManifest{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_id = test_project_id,
        .entries = &.{},
    };
    errdefer m.deinit();
    const a = m.arena.allocator();

    const entries = try a.alloc(AssetManifestEntry, entry_specs.len);
    for (entry_specs, entries) |spec, *entry| {
        entry.* = .{
            .id = try AssetId.parse(spec.id),
            .kind = spec.kind,
            .source_path = try a.dupe(u8, spec.source_path),
            .cooked_path = try a.dupe(u8, spec.cooked_path),
            .content_hash = spec.content_hash,
            .source_size = 0,
            .cooked_size = 0,
            .generated = spec.generated,
        };
    }
    m.entries = entries;
    return m;
}

const testing = std.testing;

const id_a = "3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01";
const id_b = "8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c";

test "validate accepts a sorted unique manifest" {
    var m = try testManifest(testing.allocator, &.{
        .{ .id = id_a, .source_path = "a/mesh.glb" },
        .{ .id = id_b, .source_path = "b/tex.png", .kind = .texture },
    });
    defer m.deinit();
    try m.validate();
}

test "validate rejects unsorted, duplicate, zero, and bad-path entries" {
    {
        var m = try testManifest(testing.allocator, &.{
            .{ .id = id_a, .source_path = "b/mesh.glb" },
            .{ .id = id_b, .source_path = "a/tex.png" },
        });
        defer m.deinit();
        try testing.expectError(error.CorruptManifest, m.validate());
    }
    {
        var m = try testManifest(testing.allocator, &.{
            .{ .id = id_a, .source_path = "a/mesh.glb" },
            .{ .id = id_b, .source_path = "a/mesh.glb" },
        });
        defer m.deinit();
        try testing.expectError(error.DuplicateSourcePath, m.validate());
    }
    {
        var m = try testManifest(testing.allocator, &.{
            .{ .id = id_a, .source_path = "a/mesh.glb" },
            .{ .id = id_a, .source_path = "b/tex.png" },
        });
        defer m.deinit();
        try testing.expectError(error.DuplicateAssetId, m.validate());
    }
    {
        var m = try testManifest(testing.allocator, &.{
            .{ .id = "00000000-0000-0000-0000-000000000000", .source_path = "a/mesh.glb" },
        });
        defer m.deinit();
        try testing.expectError(error.ZeroAssetId, m.validate());
    }
    {
        var m = try testManifest(testing.allocator, &.{
            .{ .id = id_a, .source_path = "../escape.glb" },
        });
        defer m.deinit();
        try testing.expectError(error.InvalidAssetPath, m.validate());
    }
    {
        var m = try testManifest(testing.allocator, &.{
            .{ .id = id_a, .source_path = "a/mesh.glb", .cooked_path = "/abs/mesh.zmesh" },
        });
        defer m.deinit();
        try testing.expectError(error.InvalidAssetPath, m.validate());
    }
}

test "findBySourcePath hits and misses" {
    var m = try testManifest(testing.allocator, &.{
        .{ .id = id_a, .source_path = "a/mesh.glb" },
        .{ .id = id_b, .source_path = "b/tex.png", .kind = .texture },
    });
    defer m.deinit();

    try testing.expect(m.findBySourcePath("a/mesh.glb").?.id.eql(try AssetId.parse(id_a)));
    try testing.expect(m.findBySourcePath("b/tex.png").?.kind == .texture);
    try testing.expect(m.findBySourcePath("c/missing.glb") == null);
}
