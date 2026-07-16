const std = @import("std");
const meta_mod = @import("meta.zig");
const AssetMeta = meta_mod.AssetMeta;
const AssetId = @import("../id/id_types.zig").AssetId;
const atomic_file = @import("../shared/atomic_file.zig");
const log = @import("../logger.zig");

/// The single component that touches sidecar files. The manifest builder
/// asks it for identities; it tracks which sidecars are new or changed and
/// flushes them only after the manifest build succeeded, so identity is
/// never persisted for a failed cook and unchanged sidecar bytes are never
/// rewritten (no spurious VCS dirt).
pub const MetaStore = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Open handle on the authored assets dir. Not owned.
    source_dir: std.Io.Dir,
    /// source_path -> loaded/created meta.
    by_source_path: std.StringHashMap(Entry),

    pub const Entry = struct {
        meta: AssetMeta,
        /// Needs writing at flush time (new file or changed contents).
        dirty: bool,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, source_dir: std.Io.Dir) MetaStore {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .io = io,
            .source_dir = source_dir,
            .by_source_path = std.StringHashMap(Entry).init(gpa),
        };
    }

    pub fn deinit(self: *MetaStore) void {
        self.by_source_path.deinit();
        self.arena.deinit();
    }

    /// Load `<source_path>.zmeta` if present. Returns null when absent.
    /// Corrupt sidecars are a hard error: silently regenerating one would
    /// silently re-identify the asset and break every reference to it.
    pub fn load(self: *MetaStore, source_path: []const u8) !?*const AssetMeta {
        if (self.by_source_path.getPtr(source_path)) |existing| return &existing.meta;

        const a = self.arena.allocator();
        const meta_path = try meta_mod.metaPathFor(a, source_path);
        const bytes = self.source_dir.readFileAlloc(
            self.io,
            meta_path,
            a,
            .limited(meta_mod.max_meta_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        const meta = meta_mod.parse(a, bytes) catch |err| {
            log.err("corrupt sidecar '{s}': {s}. Fix or restore it from VCS; " ++
                "deleting it will assign a NEW id and break references.", .{ meta_path, @errorName(err) });
            return err;
        };

        const key = try a.dupe(u8, source_path);
        try self.by_source_path.put(key, .{ .meta = meta, .dirty = false });
        return &self.by_source_path.getPtr(source_path).?.meta;
    }

    /// Record a newly assigned identity; written at flush().
    pub fn create(self: *MetaStore, source_path: []const u8, meta: AssetMeta) !void {
        const a = self.arena.allocator();
        try self.by_source_path.put(try a.dupe(u8, source_path), .{
            .meta = .{
                .id = meta.id,
                .importer = try a.dupe(u8, meta.importer),
                .importer_version = meta.importer_version,
            },
            .dirty = true,
        });
    }

    /// Update importer info on an existing entry (marks dirty only on change).
    pub fn touchImporter(self: *MetaStore, source_path: []const u8, importer: []const u8, importer_version: u32) !void {
        const entry = self.by_source_path.getPtr(source_path) orelse return;
        if (entry.meta.importer_version != importer_version or
            !std.mem.eql(u8, entry.meta.importer, importer))
        {
            entry.meta.importer = try self.arena.allocator().dupe(u8, importer);
            entry.meta.importer_version = importer_version;
            entry.dirty = true;
        }
    }

    /// Write every dirty sidecar atomically. Call ONLY after the manifest
    /// build succeeded. Returns the number of sidecars written.
    pub fn flush(self: *MetaStore, gpa: std.mem.Allocator) !usize {
        var written: usize = 0;
        var it = self.by_source_path.iterator();
        while (it.next()) |kv| {
            if (!kv.value_ptr.dirty) continue;

            const meta_path = try meta_mod.metaPathFor(gpa, kv.key_ptr.*);
            defer gpa.free(meta_path);
            const bytes = try meta_mod.serialize(gpa, &kv.value_ptr.meta);
            defer gpa.free(bytes);

            try atomic_file.writeFileAtomic(gpa, self.io, self.source_dir, meta_path, bytes);
            kv.value_ptr.dirty = false;
            written += 1;
        }
        return written;
    }
};

const testing = std.testing;

const test_id = AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01");

test "load returns null for a missing sidecar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = MetaStore.init(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();

    try testing.expectEqual(@as(?*const AssetMeta, null), try store.load("meshes/monkey.glb"));
}

test "create then flush writes a parseable sidecar exactly once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "meshes");

    var store = MetaStore.init(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();

    try store.create("meshes/monkey.glb", .{ .id = test_id, .importer = "glb", .importer_version = 1 });
    try testing.expectEqual(@as(usize, 1), try store.flush(testing.allocator));
    // Dirty was cleared: a second flush writes nothing.
    try testing.expectEqual(@as(usize, 0), try store.flush(testing.allocator));

    const bytes = try tmp.dir.readFileAlloc(testing.io, "meshes/monkey.glb.zmeta", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const meta = try meta_mod.parse(arena.allocator(), bytes);
    try testing.expect(meta.id.eql(test_id));
    try testing.expectEqualStrings("glb", meta.importer);
}

test "load reads an existing sidecar and does not mark it dirty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "a.glb.zmeta",
        .data =
        \\{"format":"zephyr.assetmeta","version":1,"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01"}
        ,
    });

    var store = MetaStore.init(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();

    const meta = (try store.load("a.glb")).?;
    try testing.expect(meta.id.eql(test_id));
    // Unchanged sidecar is never rewritten.
    try testing.expectEqual(@as(usize, 0), try store.flush(testing.allocator));
    // Second load hits the in-memory entry.
    const again = (try store.load("a.glb")).?;
    try testing.expect(again.id.eql(test_id));
}

test "corrupt sidecar is a hard error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.glb.zmeta", .data = "not json" });

    var store = MetaStore.init(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();

    try testing.expectError(error.CorruptMeta, store.load("a.glb"));
}

test "touchImporter marks dirty only on change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "a.glb.zmeta",
        .data =
        \\{"format":"zephyr.assetmeta","version":1,"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01","importer":"glb","importer_version":1}
        ,
    });

    var store = MetaStore.init(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();

    _ = (try store.load("a.glb")).?;
    try store.touchImporter("a.glb", "glb", 1);
    try testing.expectEqual(@as(usize, 0), try store.flush(testing.allocator));

    try store.touchImporter("a.glb", "glb", 2);
    try testing.expectEqual(@as(usize, 1), try store.flush(testing.allocator));
}
