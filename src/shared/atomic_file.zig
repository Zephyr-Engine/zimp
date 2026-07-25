const std = @import("std");

pub const AtomicFile = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    final_name: []u8,
    temp_name: []u8,
    closed: bool = false,
    committed: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        final_name: []const u8,
    ) !AtomicFile {
        const owned_final_name = try allocator.dupe(u8, final_name);
        errdefer allocator.free(owned_final_name);

        var nonce_bytes: [8]u8 = undefined;
        for (0..16) |_| {
            io.random(&nonce_bytes);
            const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
            const temp_name = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ final_name, nonce });
            const file = dir.createFile(io, temp_name, .{ .exclusive = true }) catch |err| {
                allocator.free(temp_name);
                if (err == error.PathAlreadyExists) continue;
                return err;
            };
            return .{
                .allocator = allocator,
                .io = io,
                .dir = dir,
                .file = file,
                .final_name = owned_final_name,
                .temp_name = temp_name,
            };
        }
        return error.UnableToCreateUniqueTempFile;
    }

    pub fn commit(self: *AtomicFile) !void {
        if (!self.closed) {
            self.file.close(self.io);
            self.closed = true;
        }
        try self.dir.rename(self.temp_name, self.dir, self.final_name, self.io);
        self.committed = true;
    }

    pub fn deinit(self: *AtomicFile) void {
        if (!self.closed) self.file.close(self.io);
        if (!self.committed) self.dir.deleteFile(self.io, self.temp_name) catch {};
        self.allocator.free(self.final_name);
        self.allocator.free(self.temp_name);
    }
};

/// Writes bytes to a unique temporary file, flushes it, then atomically
/// renames it over `final_name`.
pub fn writeFileAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    final_name: []const u8,
    bytes: []const u8,
) !void {
    var pending = try AtomicFile.create(allocator, io, dir, final_name);
    defer pending.deinit();

    var buf: [8192]u8 = undefined;
    var writer = pending.file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try pending.commit();
}

const testing = std.testing;

test "writeFileAtomic writes the final file and removes the temp file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(testing.allocator, testing.io, tmp.dir, "out.json", "{\"a\":1}");

    const bytes = try tmp.dir.readFileAlloc(testing.io, "out.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"a\":1}", bytes);

    const iterable_dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer iterable_dir.close(testing.io);
    var iter = iterable_dir.iterate();
    while (try iter.next(testing.io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, "out.json.tmp-"));
    }
}

test "writeFileAtomic replaces existing content atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(testing.allocator, testing.io, tmp.dir, "out.json", "old");
    try writeFileAtomic(testing.allocator, testing.io, tmp.dir, "out.json", "new-content");

    const bytes = try tmp.dir.readFileAlloc(testing.io, "out.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("new-content", bytes);
}
