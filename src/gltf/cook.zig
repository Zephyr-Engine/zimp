const std = @import("std");

const GLBFile = @import("glb_reader.zig").GLBFile;

pub const GLBCooker = struct {
    file: *GLBFile,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_path: []const u8) !GLBCooker {
        const file_bytes = try dir.readFileAlloc(io, file_path, allocator, .unlimited);
        defer allocator.free(file_bytes);

        const glb_file = try GLBFile.parse(allocator, file_bytes);
        return GLBCooker{
            .file = glb_file,
            .allocator = allocator,
        };
    }

    pub fn cook(_: *const GLBCooker) void {
        return;
    }

    pub fn deinit(self: *const GLBCooker) void {
        self.allocator.destroy(self.file);
    }
};
