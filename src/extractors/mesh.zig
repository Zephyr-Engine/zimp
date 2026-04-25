const std = @import("std");

const DependencyExtractor = @import("extractor.zig").DependencyExtractor;
const SourceFile = @import("../assets/source_file.zig").SourceFile;

pub fn extractor() DependencyExtractor {
    return .{ .extractFn = extractMeshDeps, .asset_type = .mesh };
}

fn extractMeshDeps(
    source: *const SourceFile,
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) ![]const SourceFile {
    _ = source;
    _ = dir;
    _ = io;
    _ = allocator;
    return &.{};
}
