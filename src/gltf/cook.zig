const std = @import("std");

const GLBFile = @import("glb_reader.zig").GLBFile;
const Gltf = @import("gltf_json_parser.zig").Gltf;
const GltfMesh = @import("mesh.zig").GltfMesh;
const CookedMesh = @import("../assets/cooked_mesh.zig").CookedMesh;
const FormatFlags = @import("../assets/cooked_mesh.zig").FormatFlags;

pub const GLBCooker = struct {
    file: *GLBFile,
    file_bytes: []const u8,
    gltf: Gltf,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_path: []const u8) !GLBCooker {
        const file_bytes = try dir.readFileAlloc(io, file_path, allocator, .unlimited);

        const glb_file = try GLBFile.parse(allocator, file_bytes);
        const gltf = try Gltf.parse(glb_file.json, allocator);

        return GLBCooker{
            .file = glb_file,
            .file_bytes = file_bytes,
            .gltf = gltf,
            .allocator = allocator,
        };
    }

    pub fn cook(self: *const GLBCooker, allocator: std.mem.Allocator) !void {
        for (0..self.gltf.value.meshes.len) |i| {
            var gltf_mesh = try GltfMesh.buildMesh(allocator, &self.gltf.value, i, self.file.bin);
            var cooked_mesh = try gltf_mesh.cook(allocator);

            defer cooked_mesh.deinit(allocator);
            defer gltf_mesh.deinit();
        }
    }

    pub fn deinit(self: *GLBCooker) void {
        self.gltf.deinit();
        self.allocator.destroy(self.file);
        self.allocator.free(self.file_bytes);
    }
};
