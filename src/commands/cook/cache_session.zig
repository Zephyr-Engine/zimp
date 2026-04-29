const std = @import("std");

const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const Cache = @import("../../cache/cache.zig").Cache;
const log = @import("../../logger.zig");
const CookContext = @import("context.zig").CookContext;

pub const CacheSession = struct {
    cache: Cache,

    pub fn open(allocator: std.mem.Allocator, ctx: *const CookContext) !CacheSession {
        const cache = blk: {
            if (ctx.force) {
                break :blk try Cache.init(allocator, ctx.source, ctx.output_path);
            }

            break :blk Cache.readFromDir(allocator, ctx.io, ctx.source, ctx.output_path) catch |err| {
                switch (err) {
                    error.OutputDirChanged => log.debug("Output directory changed, rebuilding cache", .{}),
                    error.StaleVersion => log.debug("Outdated cache version found, rebuilding entire cache", .{}),
                    error.UnsupportedVersion => log.debug("Corrupt cache found, rebuilding entire cache", .{}),
                    error.FileNotFound => log.debug("No existing cache found, starting fresh", .{}),
                    else => log.debug("Failed to read cache ({s}), starting fresh", .{@errorName(err)}),
                }
                break :blk try Cache.init(allocator, ctx.source, ctx.output_path);
            };
        };

        return .{ .cache = cache };
    }

    pub fn deinit(self: *CacheSession, allocator: std.mem.Allocator) void {
        self.cache.deinit(allocator);
    }

    pub fn pruneDeleted(self: *CacheSession, allocator: std.mem.Allocator, source_files: []const SourceFile) void {
        const pruned = self.cache.pruneDeleted(allocator, source_files);
        if (pruned > 0) {
            log.debug("Removed {d} deleted source file(s) from cache", .{pruned});
        }

        const pruned_deps = self.cache.pruneDeletedDependencyRows(allocator, source_files);
        if (pruned_deps > 0) {
            log.debug("Removed {d} deleted dependency graph row(s) from cache", .{pruned_deps});
        }
    }

    pub fn persist(self: *CacheSession, io: std.Io) !void {
        try self.cache.write(io);
    }

    pub fn cacheBytesWritten(ctx: *const CookContext) u64 {
        const cwd = std.Io.Dir.cwd();
        const cache_file = cwd.openFile(ctx.io, ".zcache", .{}) catch return 0;
        defer cache_file.close(ctx.io);

        const stat = cache_file.stat(ctx.io) catch return 0;
        return stat.size;
    }
};
