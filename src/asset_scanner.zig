const std = @import("std");

const asset = @import("asset.zig");

pub const SourceFile = struct {
    path: []const u8,
    extension: asset.Extension,
    assetType: asset.AssetType,
};

pub const SourceFileList = std.ArrayList(SourceFile);

pub const AssetScanner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    root_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, root_name: []const u8) AssetScanner {
        return .{
            .io = io,
            .dir = dir,
            .allocator = allocator,
            .root_name = root_name,
        };
    }

    pub fn scan(self: AssetScanner) !SourceFileList {
        var files: std.ArrayList(SourceFile) = .empty;
        try self.scanDir(self.dir, self.root_name, &files);
        logResults(files);

        return files;
    }

    fn scanDir(self: AssetScanner, dir: std.Io.Dir, prefix: []const u8, files: *SourceFileList) !void {
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind == .file) {
                const ext = asset.Extension.processEntry(entry);
                if (ext == .other) {
                    continue;
                }

                const path = if (prefix.len > 0)
                    try std.fs.path.join(self.allocator, &.{ prefix, entry.name })
                else
                    try self.allocator.dupe(u8, entry.name);

                try files.append(self.allocator, .{
                    .extension = ext,
                    .path = path,
                    .assetType = ext.assetType(),
                });
                std.log.info("Found {s} file: {s}", .{ ext.string(), path });
            } else if (entry.kind == .directory) {
                const subdir = try std.Io.Dir.openDir(dir, self.io, entry.name, .{ .iterate = true });
                const subprefix = if (prefix.len > 0)
                    try std.fs.path.join(self.allocator, &.{ prefix, entry.name })
                else
                    entry.name;

                defer if (prefix.len > 0) self.allocator.free(subprefix);
                try self.scanDir(subdir, subprefix, files);
            }
        }
    }

    fn logResults(files: SourceFileList) void {
        var counts = std.EnumArray(asset.AssetType, usize).initFill(0);
        for (files.items) |file| {
            counts.getPtr(file.assetType).* += 1;
        }

        std.log.info("Found {d} assets ({d} meshes)", .{
            files.items.len,
            counts.get(.mesh),
        });
    }

    pub fn deinit(self: AssetScanner, list: *SourceFileList) void {
        for (list.items) |file| {
            self.allocator.free(file.path);
        }
        list.deinit(self.allocator);
    }
};
