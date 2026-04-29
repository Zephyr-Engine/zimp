const std = @import("std");

const SourceFile = @import("../assets/source_file.zig").SourceFile;
const Hash = @import("../assets/source_file.zig").Hash;

pub const DependencyRef = struct {
    path: []const u8,
    path_hash: Hash,
};

pub const DependencyRow = struct {
    source_path: []const u8,
    source_path_hash: Hash,
    source_size: u64,
    source_mtime: i96,
    dependencies: std.ArrayList(DependencyRef),

    pub fn deinit(self: *DependencyRow, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        for (self.dependencies.items) |dep| {
            allocator.free(dep.path);
        }
        self.dependencies.deinit(allocator);
    }

    pub fn isFresh(self: *const DependencyRow, info: SourceFile.FileInfo) bool {
        return self.source_size == info.size and self.source_mtime == info.modified_ns;
    }

    pub fn create(
        allocator: std.mem.Allocator,
        source: SourceFile,
        info: SourceFile.FileInfo,
        dependencies: []const SourceFile,
    ) !DependencyRow {
        const source_path = try allocator.dupe(u8, source.path);
        errdefer allocator.free(source_path);

        var refs: std.ArrayList(DependencyRef) = .empty;
        errdefer {
            for (refs.items) |dep| allocator.free(dep.path);
            refs.deinit(allocator);
        }

        try refs.ensureTotalCapacity(allocator, dependencies.len);
        for (dependencies) |dep| {
            const dep_path = try allocator.dupe(u8, dep.path);
            errdefer allocator.free(dep_path);
            refs.appendAssumeCapacity(.{
                .path = dep_path,
                .path_hash = dep.hashPath(),
            });
        }

        return .{
            .source_path = source_path,
            .source_path_hash = source.hashPath(),
            .source_size = info.size,
            .source_mtime = info.modified_ns,
            .dependencies = refs,
        };
    }
};

pub const CacheDepGraph = struct {
    rows: std.ArrayList(DependencyRow) = .empty,
    row_map: std.AutoHashMap(Hash, u32),

    pub fn init(allocator: std.mem.Allocator) CacheDepGraph {
        return .{ .row_map = .init(allocator) };
    }

    pub fn deinit(self: *CacheDepGraph, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| {
            row.deinit(allocator);
        }
        self.rows.deinit(allocator);
        self.row_map.deinit();
    }

    pub fn get(self: *const CacheDepGraph, source: SourceFile) ?*const DependencyRow {
        const idx = self.row_map.get(source.hashPath()) orelse return null;
        return &self.rows.items[idx];
    }

    pub fn upsert(self: *CacheDepGraph, allocator: std.mem.Allocator, row: DependencyRow) !void {
        if (self.row_map.get(row.source_path_hash)) |idx| {
            self.rows.items[idx].deinit(allocator);
            self.rows.items[idx] = row;
            return;
        }

        const idx = self.rows.items.len;
        try self.rows.ensureUnusedCapacity(allocator, 1);
        try self.row_map.ensureUnusedCapacity(1);
        self.rows.appendAssumeCapacity(row);
        self.row_map.putAssumeCapacity(row.source_path_hash, @intCast(idx));
    }

    pub fn pruneDeleted(self: *CacheDepGraph, allocator: std.mem.Allocator, source_files: []const SourceFile) u32 {
        var source_hashes: std.AutoHashMap(Hash, void) = .init(allocator);
        defer source_hashes.deinit();

        const has_hash_set = blk: {
            source_hashes.ensureTotalCapacity(@intCast(source_files.len)) catch break :blk false;
            for (source_files) |sf| {
                source_hashes.putAssumeCapacity(sf.hashPath(), {});
            }
            break :blk true;
        };

        var removed: u32 = 0;
        var i: usize = 0;
        while (i < self.rows.items.len) {
            const source_hash = self.rows.items[i].source_path_hash;
            const exists = if (has_hash_set)
                source_hashes.contains(source_hash)
            else
                sourceExistsSlow(source_files, source_hash);

            if (!exists) {
                self.rows.items[i].deinit(allocator);
                _ = self.rows.orderedRemove(i);
                _ = self.row_map.remove(source_hash);
                removed += 1;
            } else {
                i += 1;
            }
        }

        if (removed > 0) {
            self.rebuildMap();
        }

        return removed;
    }

    pub fn totalEdgeCount(self: *const CacheDepGraph) usize {
        var total: usize = 0;
        for (self.rows.items) |row| {
            total += row.dependencies.items.len;
        }
        return total;
    }

    fn rebuildMap(self: *CacheDepGraph) void {
        self.row_map.clearRetainingCapacity();
        for (self.rows.items, 0..) |row, idx| {
            self.row_map.putAssumeCapacity(row.source_path_hash, @intCast(idx));
        }
    }
};

fn sourceExistsSlow(source_files: []const SourceFile, source_hash: Hash) bool {
    for (source_files) |sf| {
        if (sf.hashPath() == source_hash) return true;
    }
    return false;
}

const testing = std.testing;

test "DependencyRow.create owns source and dependency paths" {
    const source = SourceFile.fromPath("shaders/main.frag");
    const deps = [_]SourceFile{
        SourceFile.fromPath("shaders/common.glsl"),
        SourceFile.fromPath("shared/light.glsl"),
    };

    var row = try DependencyRow.create(testing.allocator, source, .{
        .size = 10,
        .modified_ns = 20,
    }, &deps);
    defer row.deinit(testing.allocator);

    try testing.expectEqualStrings("shaders/main.frag", row.source_path);
    try testing.expectEqual(source.hashPath(), row.source_path_hash);
    try testing.expectEqual(@as(usize, 2), row.dependencies.items.len);
    try testing.expectEqualStrings("shaders/common.glsl", row.dependencies.items[0].path);
    try testing.expect(row.source_path.ptr != source.path.ptr);
}

test "CacheDepGraph.upsert replaces an existing row" {
    var graph = CacheDepGraph.init(testing.allocator);
    defer graph.deinit(testing.allocator);

    const source = SourceFile.fromPath("main.frag");
    const dep_a = [_]SourceFile{SourceFile.fromPath("a.glsl")};
    const dep_b = [_]SourceFile{SourceFile.fromPath("b.glsl")};

    try graph.upsert(testing.allocator, try DependencyRow.create(testing.allocator, source, .{
        .size = 1,
        .modified_ns = 1,
    }, &dep_a));
    try graph.upsert(testing.allocator, try DependencyRow.create(testing.allocator, source, .{
        .size = 2,
        .modified_ns = 2,
    }, &dep_b));

    try testing.expectEqual(@as(usize, 1), graph.rows.items.len);
    const row = graph.get(source).?;
    try testing.expectEqual(@as(u64, 2), row.source_size);
    try testing.expectEqualStrings("b.glsl", row.dependencies.items[0].path);
}

test "CacheDepGraph.pruneDeleted removes missing sources and rebuilds index" {
    var graph = CacheDepGraph.init(testing.allocator);
    defer graph.deinit(testing.allocator);

    const a = SourceFile.fromPath("a.frag");
    const b = SourceFile.fromPath("b.frag");
    try graph.upsert(testing.allocator, try DependencyRow.create(testing.allocator, a, .{
        .size = 1,
        .modified_ns = 1,
    }, &.{}));
    try graph.upsert(testing.allocator, try DependencyRow.create(testing.allocator, b, .{
        .size = 1,
        .modified_ns = 1,
    }, &.{}));

    const removed = graph.pruneDeleted(testing.allocator, &.{b});
    try testing.expectEqual(@as(u32, 1), removed);
    try testing.expect(graph.get(a) == null);
    try testing.expect(graph.get(b) != null);
}
