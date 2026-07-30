const std = @import("std");

pub const MeshScratch = struct {
    allocator: std.mem.Allocator,
    remap: std.ArrayList(u32) = .empty,
    candidates: std.ArrayList(u32) = .empty,
    used: std.ArrayList(bool) = .empty,

    pub fn init(allocator: std.mem.Allocator) MeshScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MeshScratch) void {
        self.remap.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.used.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn remapFor(self: *MeshScratch, len: usize) ![]u32 {
        try self.remap.resize(self.allocator, len);
        return self.remap.items;
    }

    pub fn candidatesFor(self: *MeshScratch, len: usize) ![]u32 {
        try self.candidates.resize(self.allocator, len);
        return self.candidates.items;
    }

    pub fn usedFor(self: *MeshScratch, len: usize) ![]bool {
        try self.used.resize(self.allocator, len);
        return self.used.items;
    }
};
