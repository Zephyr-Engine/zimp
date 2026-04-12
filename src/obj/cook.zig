const std = @import("std");

const ZMesh = @import("../formats/zmesh.zig").ZMesh;
const ObjParser = @import("obj_parser.zig").ObjParser;
const CookedMesh = @import("../assets/cooked/mesh.zig").CookedMesh;

pub const OBJCooker = struct {
    parser: ObjParser,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_path: []const u8) !OBJCooker {
        const parser = try ObjParser.init(allocator, io, dir, file_path);
        return .{
            .parser = parser,
        };
    }

    pub fn cook(self: *const OBJCooker, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
        var raw_mesh = try self.parser.parse(allocator);
        defer allocator.free(raw_mesh.vertices);
        defer allocator.free(raw_mesh.indices);
        defer allocator.free(raw_mesh.submeshes);

        var cooked_mesh = try CookedMesh.cook(allocator, &raw_mesh);
        defer cooked_mesh.deinit(allocator);

        try ZMesh.write(writer, cooked_mesh);
    }

    pub fn deinit(self: *OBJCooker) void {
        self.parser.deinit();
    }
};
