const std = @import("std");

pub const Extension = enum {
    gltf,
    other,

    pub fn string(self: Extension) []const u8 {
        return switch (self) {
            .gltf => "gltf",
            .other => "other",
        };
    }
};

const map = std.StaticStringMap(Extension).initComptime(.{
    .{ "gltf", .gltf },
});

pub const SourceFile = struct {
    path: []const u8,
    extension: Extension,
    size: u64,
};

pub const SourceFileList = std.ArrayList(SourceFile);

pub const AssetScanner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) AssetScanner {
        return .{
            .io = io,
            .dir = dir,
            .allocator = allocator,
        };
    }

    pub fn scan(self: AssetScanner) !SourceFileList {
        var files: std.ArrayList(SourceFile) = .empty;
        try self.scanDir(self.dir, &files);
        return files;
    }

    fn scanDir(self: AssetScanner, dir: std.Io.Dir, files: *SourceFileList) !void {
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind == .file) {
                const ext = processEntry(entry);
                if (ext != .other) {
                    try files.append(self.allocator, .{
                        .extension = ext,
                        .path = entry.name,
                        .size = 0,
                    });
                    std.log.info("Found {s} file: {s}", .{ Extension.gltf.string(), entry.name });
                }
            } else if (entry.kind == .directory) {
                const subdir = try std.Io.Dir.openDir(dir, self.io, entry.name, .{ .iterate = true });
                try self.scanDir(subdir, files);
            }
        }
    }

    fn processEntry(entry: std.Io.Dir.Entry) Extension {
        var iter = std.mem.splitScalar(u8, entry.name, '.');
        // ignore filename itself
        _ = iter.next();

        if (iter.next()) |ext| {
            if (map.get(ext)) |ex| {
                return ex;
            }
        }
        return .other;
    }
};
