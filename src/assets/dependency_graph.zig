const std = @import("std");

const source_file_mod = @import("source_file.zig");
const SourceFile = source_file_mod.SourceFile;
const Hash = source_file_mod.Hash;

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
