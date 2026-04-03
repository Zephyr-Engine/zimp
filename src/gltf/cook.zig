const std = @import("std");

const GLBFile = @import("glb_reader.zig").GLBFile;
const Gltf = @import("gltf_json_parser.zig").Gltf;

pub const GLBCooker = struct {
    file: *GLBFile,
    gltf: Gltf,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_path: []const u8) !GLBCooker {
        const file_bytes = try dir.readFileAlloc(io, file_path, allocator, .unlimited);
        defer allocator.free(file_bytes);

        const glb_file = try GLBFile.parse(allocator, file_bytes);
        const gltf = try Gltf.parse(glb_file.json, allocator);

        return GLBCooker{
            .file = glb_file,
            .gltf = gltf,
            .allocator = allocator,
        };
    }

    pub fn cook(_: *const GLBCooker) void {
        return;
    }

    pub fn deinit(self: *GLBCooker) void {
        self.gltf.deinit();
        self.allocator.destroy(self.file);
    }
};
