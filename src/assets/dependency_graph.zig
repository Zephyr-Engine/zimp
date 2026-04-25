const std = @import("std");

const source_file_mod = @import("source_file.zig");
const SourceFile = source_file_mod.SourceFile;
const Hash = source_file_mod.Hash;
const log = @import("../logger.zig");

const Dependencies = std.ArrayList(Hash);
const Edges = std.AutoHashMap(Hash, Dependencies);
const ReverseEdges = std.AutoHashMap(Hash, Dependencies);

pub const DepGraph = struct {
    edges: Edges,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DepGraph {
        return .{
            .edges = Edges.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DepGraph) void {
        var iter = self.edges.iterator();
        while (iter.next()) |edge| {
            edge.value_ptr.deinit(self.allocator);
        }

        self.edges.deinit();
    }

    pub fn addDependency(self: *DepGraph, from: Hash, to: Hash) !void {
        const gop = try self.edges.getOrPut(from);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        } else {
            // exit early if dependency is already present
            for (gop.value_ptr.items) |to_hash| {
                if (to_hash == to) {
                    return;
                }
            }
        }

        try gop.value_ptr.append(self.allocator, to);
    }

    pub fn getDependencies(self: *const DepGraph, source: *const SourceFile) ?Dependencies {
        return self.edges.get(source.hashPath());
    }

    pub fn dependencyCount(self: *const DepGraph, source: *const SourceFile) usize {
        if (self.edges.get(source.hashPath())) |entry| {
            return entry.items.len;
        }

        return 0;
    }

    pub fn totalDependencyCount(self: *const DepGraph) usize {
        var total_len: usize = 0;

        var iter = self.edges.iterator();
        while (iter.next()) |edge| {
            total_len += edge.value_ptr.items.len;
        }

        return total_len;
    }

    pub fn freeLevels(allocator: std.mem.Allocator, levels: [][]SourceFile) void {
        for (levels) |level| {
            allocator.free(level);
        }
        allocator.free(levels);
    }

    pub fn cookLevels(self: *const DepGraph, files: []const SourceFile) ![][]SourceFile {
        const allocator = self.allocator;

        var node_map: std.AutoHashMap(Hash, SourceFile) = .init(allocator);
        defer node_map.deinit();
        for (files) |file| {
            try node_map.put(file.hashPath(), file);
        }

        var in_degree: std.AutoHashMap(Hash, usize) = .init(allocator);
        defer in_degree.deinit();

        var dependents: std.AutoHashMap(Hash, Dependencies) = .init(allocator);
        defer {
            var dep_iter = dependents.iterator();
            while (dep_iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            dependents.deinit();
        }

        for (files) |file| {
            const from = file.hashPath();
            var count: usize = 0;
            if (self.edges.get(from)) |deps| {
                for (deps.items) |to| {
                    if (!node_map.contains(to)) {
                        continue;
                    }
                    count += 1;
                    const gop = try dependents.getOrPut(to);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .empty;
                    }
                    try gop.value_ptr.append(allocator, from);
                }
            }
            try in_degree.put(from, count);
        }

        var levels: std.ArrayList([]SourceFile) = .empty;
        errdefer {
            for (levels.items) |level| allocator.free(level);
            levels.deinit(allocator);
        }

        var current: std.ArrayList(SourceFile) = .empty;
        defer current.deinit(allocator);
        var next: std.ArrayList(SourceFile) = .empty;
        defer next.deinit(allocator);

        for (files) |file| {
            const h = file.hashPath();
            if (in_degree.get(h).? == 0) {
                try current.append(allocator, file);
            }
        }

        var emitted: usize = 0;
        while (current.items.len > 0) {
            emitted += current.items.len;

            const level = try allocator.dupe(SourceFile, current.items);
            levels.append(allocator, level) catch |err| {
                allocator.free(level);
                return err;
            };

            next.clearRetainingCapacity();
            for (current.items) |file| {
                if (dependents.get(file.hashPath())) |dep_list| {
                    for (dep_list.items) |dependent| {
                        const entry = in_degree.getPtr(dependent).?;
                        entry.* -= 1;
                        if (entry.* == 0) {
                            try next.append(allocator, node_map.get(dependent).?);
                        }
                    }
                }
            }

            const tmp = current;
            current = next;
            next = tmp;
        }

        if (emitted < files.len) {
            log.err("Cycle detected in dependency graph. Files involved:", .{});
            var iter = in_degree.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* > 0) {
                    if (node_map.get(entry.key_ptr.*)) |file| {
                        log.err("  {s}", .{file.path});
                    }
                }
            }
            return error.CycleDetected;
        }

        return levels.toOwnedSlice(allocator);
    }

    pub fn buildReverse(self: *const DepGraph, allocator: std.mem.Allocator) !ReverseEdges {
        var reverseMap: ReverseEdges = .init(allocator);
        errdefer {
            var iter = reverseMap.iterator();
            while (iter.next()) |entry| entry.value_ptr.deinit(allocator);
            reverseMap.deinit();
        }

        var iter = self.edges.iterator();
        while (iter.next()) |entry| {
            const from = entry.key_ptr.*;
            for (entry.value_ptr.items) |to| {
                const gop = try reverseMap.getOrPut(to);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(allocator, from);
            }
        }

        return reverseMap;
    }
};

const testing = std.testing;

fn deinitReverseEdges(reverse: *ReverseEdges) void {
    var iter = reverse.iterator();
    while (iter.next()) |entry| entry.value_ptr.deinit(testing.allocator);
    reverse.deinit();
}

test "DepGraph.buildReverse empty graph produces empty map" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    var reverse = try graph.buildReverse(testing.allocator);
    defer deinitReverseEdges(&reverse);

    try testing.expectEqual(0, reverse.count());
}

test "DepGraph.buildReverse single edge A->B produces B->[A]" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.addDependency(1, 2);

    var reverse = try graph.buildReverse(testing.allocator);
    defer deinitReverseEdges(&reverse);

    const deps = reverse.get(2) orelse return error.MissingKey;
    try testing.expectEqual(1, deps.items.len);
    try testing.expectEqual(@as(Hash, 1), deps.items[0]);
}

test "DepGraph.buildReverse A->[B,C] produces B->[A] and C->[A]" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.addDependency(1, 2);
    try graph.addDependency(1, 3);

    var reverse = try graph.buildReverse(testing.allocator);
    defer deinitReverseEdges(&reverse);

    const deps_b = reverse.get(2) orelse return error.MissingKey;
    try testing.expectEqual(1, deps_b.items.len);
    try testing.expectEqual(@as(Hash, 1), deps_b.items[0]);

    const deps_c = reverse.get(3) orelse return error.MissingKey;
    try testing.expectEqual(1, deps_c.items.len);
    try testing.expectEqual(@as(Hash, 1), deps_c.items[0]);
}

test "DepGraph.buildReverse A->B and C->B produces B with both A and C as dependents" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.addDependency(1, 2);
    try graph.addDependency(3, 2);

    var reverse = try graph.buildReverse(testing.allocator);
    defer deinitReverseEdges(&reverse);

    const deps = reverse.get(2) orelse return error.MissingKey;
    try testing.expectEqual(2, deps.items.len);

    var has_1 = false;
    var has_3 = false;
    for (deps.items) |d| {
        if (d == 1) has_1 = true;
        if (d == 3) has_3 = true;
    }
    try testing.expect(has_1);
    try testing.expect(has_3);
}

test "DepGraph.buildReverse chain A->B->C produces B->[A] and C->[B]" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.addDependency(1, 2);
    try graph.addDependency(2, 3);

    var reverse = try graph.buildReverse(testing.allocator);
    defer deinitReverseEdges(&reverse);

    const deps_b = reverse.get(2) orelse return error.MissingKey;
    try testing.expectEqual(1, deps_b.items.len);
    try testing.expectEqual(@as(Hash, 1), deps_b.items[0]);

    const deps_c = reverse.get(3) orelse return error.MissingKey;
    try testing.expectEqual(1, deps_c.items.len);
    try testing.expectEqual(@as(Hash, 2), deps_c.items[0]);
}

test "DepGraph.buildReverse source-only node does not appear as a key" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try graph.addDependency(1, 2);

    var reverse = try graph.buildReverse(testing.allocator);
    defer deinitReverseEdges(&reverse);

    try testing.expect(reverse.get(1) == null);
    try testing.expect(reverse.get(2) != null);
}

fn indexOfPath(files: []const SourceFile, path: []const u8) ?usize {
    for (files, 0..) |file, i| {
        if (std.mem.eql(u8, file.path, path)) return i;
    }
    return null;
}

fn levelOfPath(levels: [][]SourceFile, path: []const u8) ?usize {
    for (levels, 0..) |level, i| {
        if (indexOfPath(level, path) != null) return i;
    }
    return null;
}

test "DepGraph.cookLevels places shader in earlier level than dependent material" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const shader = SourceFile.fromPath("shaders/lit.glsl");
    const material = SourceFile.fromPath("materials/lit.mat");
    try graph.addDependency(material.hashPath(), shader.hashPath());

    const files = [_]SourceFile{ material, shader };
    const levels = try graph.cookLevels(&files);
    defer DepGraph.freeLevels(testing.allocator, levels);

    const shader_level = levelOfPath(levels, "shaders/lit.glsl") orelse return error.MissingShader;
    const material_level = levelOfPath(levels, "materials/lit.mat") orelse return error.MissingMaterial;
    try testing.expect(shader_level < material_level);
}

test "DepGraph.cookLevels produces three single-element levels for chain A->B->C" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const a = SourceFile.fromPath("a.glsl");
    const b = SourceFile.fromPath("b.glsl");
    const c = SourceFile.fromPath("c.glsl");
    try graph.addDependency(a.hashPath(), b.hashPath());
    try graph.addDependency(b.hashPath(), c.hashPath());

    const files = [_]SourceFile{ a, b, c };
    const levels = try graph.cookLevels(&files);
    defer DepGraph.freeLevels(testing.allocator, levels);

    try testing.expectEqual(@as(usize, 3), levels.len);
    try testing.expectEqual(@as(usize, 1), levels[0].len);
    try testing.expectEqualStrings("c.glsl", levels[0][0].path);
    try testing.expectEqual(@as(usize, 1), levels[1].len);
    try testing.expectEqualStrings("b.glsl", levels[1][0].path);
    try testing.expectEqual(@as(usize, 1), levels[2].len);
    try testing.expectEqualStrings("a.glsl", levels[2][0].path);
}

test "DepGraph.cookLevels groups independent files into a single level" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const files = [_]SourceFile{
        SourceFile.fromPath("a.glsl"),
        SourceFile.fromPath("b.glsl"),
        SourceFile.fromPath("c.glsl"),
    };
    const levels = try graph.cookLevels(&files);
    defer DepGraph.freeLevels(testing.allocator, levels);

    try testing.expectEqual(@as(usize, 1), levels.len);
    try testing.expectEqual(@as(usize, 3), levels[0].len);
    try testing.expect(indexOfPath(levels[0], "a.glsl") != null);
    try testing.expect(indexOfPath(levels[0], "b.glsl") != null);
    try testing.expect(indexOfPath(levels[0], "c.glsl") != null);
}

test "DepGraph.cookLevels groups two roots and shared dependent into two levels" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const a = SourceFile.fromPath("a.glsl");
    const b = SourceFile.fromPath("b.glsl");
    const c = SourceFile.fromPath("c.glsl");
    try graph.addDependency(c.hashPath(), a.hashPath());
    try graph.addDependency(c.hashPath(), b.hashPath());

    const files = [_]SourceFile{ a, b, c };
    const levels = try graph.cookLevels(&files);
    defer DepGraph.freeLevels(testing.allocator, levels);

    try testing.expectEqual(@as(usize, 2), levels.len);
    try testing.expectEqual(@as(usize, 2), levels[0].len);
    try testing.expect(indexOfPath(levels[0], "a.glsl") != null);
    try testing.expect(indexOfPath(levels[0], "b.glsl") != null);
    try testing.expectEqual(@as(usize, 1), levels[1].len);
    try testing.expectEqualStrings("c.glsl", levels[1][0].path);
}

test "DepGraph.cookLevels returns CycleDetected for A->B->A" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const a = SourceFile.fromPath("a.glsl");
    const b = SourceFile.fromPath("b.glsl");
    try graph.addDependency(a.hashPath(), b.hashPath());
    try graph.addDependency(b.hashPath(), a.hashPath());

    const files = [_]SourceFile{ a, b };
    try testing.expectError(error.CycleDetected, graph.cookLevels(&files));
}

test "DepGraph.cookLevels ignores deps on non-cookable targets" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const a = SourceFile.fromPath("a.glsl");
    const non_cookable_hash: Hash = 0xDEADBEEFCAFEBABE;
    try graph.addDependency(a.hashPath(), non_cookable_hash);

    const files = [_]SourceFile{a};
    const levels = try graph.cookLevels(&files);
    defer DepGraph.freeLevels(testing.allocator, levels);

    try testing.expectEqual(@as(usize, 1), levels.len);
    try testing.expectEqual(@as(usize, 1), levels[0].len);
    try testing.expectEqualStrings("a.glsl", levels[0][0].path);
}

test "DepGraph.cookLevels returns empty slice for empty input" {
    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    const files: []const SourceFile = &.{};
    const levels = try graph.cookLevels(files);
    defer DepGraph.freeLevels(testing.allocator, levels);

    try testing.expectEqual(@as(usize, 0), levels.len);
}
