const std = @import("std");

const Hash = @import("source_file.zig").Hash;

const Dependencies = std.ArrayList(Hash);
const Edges = std.AutoHashMap(Hash, Dependencies);

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
            for (gop.value_ptr.items) |existing| {
                if (existing == to) return;
            }
        }
        try gop.value_ptr.append(self.allocator, to);
    }

    pub fn getDependenciesByHash(self: *const DepGraph, source: Hash) ?Dependencies {
        return self.edges.get(source);
    }

    pub fn totalDependencyCount(self: *const DepGraph) usize {
        var total: usize = 0;
        var iter = self.edges.iterator();
        while (iter.next()) |edge| {
            total += edge.value_ptr.items.len;
        }
        return total;
    }
};

test "duplicate dependencies are stored once" {
    var graph = DepGraph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addDependency(1, 2);
    try graph.addDependency(1, 2);

    try std.testing.expectEqual(@as(usize, 1), graph.totalDependencyCount());
    try std.testing.expectEqualSlices(Hash, &.{2}, graph.getDependenciesByHash(1).?.items);
}
