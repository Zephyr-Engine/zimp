const std = @import("std");

const asset = @import("../assets/asset.zig");
const meta = @import("../manifest/meta.zig");
const log = @import("../logger.zig");

pub const FileState = struct {
    size: u64,
    mtime_ns: i96,
};

const Snapshot = @This();

arena: std.heap.ArenaAllocator,
files: std.StringHashMapUnmanaged(FileState),

pub fn deinit(self: *Snapshot) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn eql(s1: *const Snapshot, s2: *const Snapshot) bool {
    if (s1.files.count() != s2.files.count()) {
        return false;
    }

    var iter = s2.files.iterator();
    while (iter.next()) |kv| {
        const prev = s1.files.get(kv.key_ptr.*) orelse return false;
        if (prev.size != kv.value_ptr.size) {
            return false;
        }

        if (prev.mtime_ns != kv.value_ptr.mtime_ns) {
            return false;
        }
    }

    return true;
}

pub fn logDiff(s1: *const Snapshot, s2: *const Snapshot) void {
    var s2_iter = s2.files.iterator();
    while (s2_iter.next()) |kv| {
        if (s1.files.get(kv.key_ptr.*)) |prev| {
            if (prev.size != kv.value_ptr.size or prev.mtime_ns != kv.value_ptr.mtime_ns) {
                log.info("watch: modified '{s}'", .{kv.key_ptr.*});
            }
        } else {
            log.info("watch: added '{s}'", .{kv.key_ptr.*});
        }
    }

    var s1_iter = s1.files.iterator();
    while (s1_iter.next()) |kv| {
        if (s2.files.get(kv.key_ptr.*) == null) {
            log.info("watch: removed '{s}'", .{kv.key_ptr.*});
        }
    }
}

pub fn capture(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Snapshot {
    var snapshot = Snapshot{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .files = .empty,
    };
    errdefer snapshot.deinit();

    try snapshot.captureDir(io, dir, "");
    return snapshot;
}

fn captureDir(self: *Snapshot, io: std.Io, dir: std.Io.Dir, prefix: []const u8) !void {
    const gpa = self.arena.allocator();

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                // never process sidecar files, they get automatically handled by the cooker
                if (meta.isMetaPath(entry.name)) {
                    continue;
                }

                // only handle files that can be cooked
                if (asset.Extension.processEntry(entry) == .other) {
                    continue;
                }

                const stat = statFile(io, dir, entry.name) catch |err| {
                    log.warn("watch: stat failed for '{s}': {s}", .{ entry.name, @errorName(err) });
                    continue;
                };

                const path = if (prefix.len > 0)
                    try std.fs.path.join(gpa, &.{ prefix, entry.name })
                else
                    try gpa.dupe(u8, entry.name);

                try self.files.put(gpa, path, stat);
            },
            .directory => {
                const subdir = std.Io.Dir.openDir(dir, io, entry.name, .{ .iterate = true }) catch |err| {
                    log.err("watch: 'open dir '{s}' failed: {s}", .{ entry.name, @errorName(err) });
                    continue;
                };
                defer subdir.close(io);

                const subprefix = if (prefix.len > 0)
                    try std.fs.path.join(gpa, &.{ prefix, entry.name })
                else
                    try gpa.dupe(u8, entry.name);

                try self.captureDir(io, subdir, subprefix);
            },
            else => {},
        }
    }
}

fn statFile(io: std.Io, dir: std.Io.Dir, name: []const u8) !FileState {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    return .{
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
    };
}

const testing = std.testing;

fn writeFile(tmp: std.testing.TmpDir, path: []const u8, contents: []const u8) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = contents });
}

test "capture recursively records cookable files and ignores sidecars and unknown files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "assets/shaders");
    try writeFile(tmp, "model.gltf", "gltf");
    try writeFile(tmp, "assets/albedo.png", "png");
    try writeFile(tmp, "assets/shaders/lighting.frag", "fragment shader");
    try writeFile(tmp, "model.gltf.zmeta", "sidecar");
    try writeFile(tmp, "assets/albedo.png.zmeta", "sidecar");
    try writeFile(tmp, "assets/shaders/notes.txt", "not cookable");
    try writeFile(tmp, "README", "not cookable");

    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);

    var snapshot = try capture(testing.allocator, testing.io, dir);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 3), snapshot.files.count());
    try testing.expectEqual(FileState{ .size = 4, .mtime_ns = snapshot.files.get("model.gltf").?.mtime_ns }, snapshot.files.get("model.gltf").?);
    try testing.expectEqual(@as(u64, 3), snapshot.files.get("assets/albedo.png").?.size);
    try testing.expectEqual(@as(u64, 15), snapshot.files.get("assets/shaders/lighting.frag").?.size);
    try testing.expect(snapshot.files.get("model.gltf.zmeta") == null);
    try testing.expect(snapshot.files.get("assets/albedo.png.zmeta") == null);
    try testing.expect(snapshot.files.get("assets/shaders/notes.txt") == null);
    try testing.expect(snapshot.files.get("README") == null);
}

test "capture returns an empty snapshot when no cookable files exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "empty/nested");
    try writeFile(tmp, "empty/nested/notes.txt", "ignored");
    try writeFile(tmp, "source.obj.zmeta", "ignored sidecar");

    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);

    var snapshot = try capture(testing.allocator, testing.io, dir);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 0), snapshot.files.count());
}

test "eql detects unchanged, modified, added, and removed files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp, "a.obj", "v 0 0 0");

    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);

    var initial = try capture(testing.allocator, testing.io, dir);
    defer initial.deinit();

    var unchanged = try capture(testing.allocator, testing.io, dir);
    defer unchanged.deinit();
    try testing.expect(eql(&initial, &unchanged));

    try writeFile(tmp, "a.obj", "v 0 0 0\nv 1 1 1");
    var modified = try capture(testing.allocator, testing.io, dir);
    defer modified.deinit();
    try testing.expect(!eql(&initial, &modified));

    try writeFile(tmp, "b.obj", "v 2 2 2");
    var added = try capture(testing.allocator, testing.io, dir);
    defer added.deinit();
    try testing.expect(!eql(&modified, &added));

    try tmp.dir.deleteFile(testing.io, "b.obj");
    var removed = try capture(testing.allocator, testing.io, dir);
    defer removed.deinit();
    try testing.expect(!eql(&added, &removed));
    try testing.expect(eql(&modified, &removed));
}

test "eql detects timestamp-only changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp, "model.glb", "mesh");

    const dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);

    var original = try capture(testing.allocator, testing.io, dir);
    defer original.deinit();
    var changed_timestamp = try capture(testing.allocator, testing.io, dir);
    defer changed_timestamp.deinit();

    changed_timestamp.files.getPtr("model.glb").?.mtime_ns += 1;
    try testing.expect(!eql(&original, &changed_timestamp));
}
