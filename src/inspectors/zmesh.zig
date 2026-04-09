const std = @import("std");
const log = @import("../logger.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;

fn inspectZamesh(allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
    _ = allocator;
    _ = reader;
    log.info("INSPECTING ZMESH", .{});
    // Reader is already past the 4-byte magic
    // const header = try readHeader(reader);
    // try validateHeader(header);
    //
    // log.info("zamesh v{d}", .{header.version});
    // log.info("  Vertices:  {d}", .{header.vertex_count});
    // log.info("  Indices:   {d}", .{header.index_count});
    // log.info("  Triangles: {d}", .{header.index_count / 3});
    // ... stream layout, submesh table, file size summary
}

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZamesh };
}
