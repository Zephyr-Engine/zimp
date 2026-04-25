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

    pub fn buildReverse(self: *const DepGraph, allocator: std.mem.Allocator) ReverseEdges {
        var reverseMap: ReverseEdges = .init(allocator);
        errdefer reverseMap.deinit();

        var keyIter = self.edges.keyIterator();
        while (keyIter.next()) |key| {
            var reverseValues: Dependencies = .empty;
            var valueIter = self.edges.valueIterator();
            while (valueIter.next()) |value| {
                for (value.items) |dep| {
                    if (dep == value) {
                        try reverseValues.append(allocator, key);
                    }
                }
            }
            if (reverseValues.items.len != 0) {
                reverseMap.put(key, reverseValues);
            }
        }
    }
};
