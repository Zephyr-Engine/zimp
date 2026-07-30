const std = @import("std");

pub const CountingAllocator = struct {
    /// Must be thread-safe because cooking can allocate concurrently.
    backing_allocator: std.mem.Allocator,
    current_requested_bytes: std.atomic.Value(usize) = .init(0),
    peak_requested_bytes: std.atomic.Value(usize) = .init(0),

    pub fn init(backing_allocator: std.mem.Allocator) CountingAllocator {
        return .{ .backing_allocator = backing_allocator };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn recordGrowth(self: *CountingAllocator, delta: usize) void {
        const current = self.current_requested_bytes.fetchAdd(delta, .monotonic) +| delta;
        _ = self.peak_requested_bytes.fetchMax(current, .monotonic);
    }

    fn recordShrink(self: *CountingAllocator, delta: usize) void {
        _ = self.current_requested_bytes.fetchSub(delta, .monotonic);
    }

    pub fn currentRequestedBytes(self: *const CountingAllocator) usize {
        return self.current_requested_bytes.load(.monotonic);
    }

    pub fn peakRequestedBytes(self: *const CountingAllocator) usize {
        return self.peak_requested_bytes.load(.monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.recordGrowth(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing_allocator.rawResize(memory, alignment, new_len, ret_addr);
        if (!ok) return false;

        if (new_len >= memory.len) {
            self.recordGrowth(new_len - memory.len);
        } else {
            self.recordShrink(memory.len - new_len);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        if (new_len >= memory.len) {
            self.recordGrowth(new_len - memory.len);
        } else {
            self.recordShrink(memory.len - new_len);
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
        self.recordShrink(memory.len);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const testing = std.testing;

test "CountingAllocator tracks current and peak requested bytes" {
    var tracker = CountingAllocator.init(testing.allocator);
    const allocator = tracker.allocator();

    const a = try allocator.alloc(u8, 64);
    defer allocator.free(a);
    try testing.expectEqual(@as(usize, 64), tracker.currentRequestedBytes());
    try testing.expectEqual(@as(usize, 64), tracker.peakRequestedBytes());

    const b = try allocator.alloc(u8, 32);
    defer allocator.free(b);
    try testing.expectEqual(@as(usize, 96), tracker.currentRequestedBytes());
    try testing.expectEqual(@as(usize, 96), tracker.peakRequestedBytes());
}
