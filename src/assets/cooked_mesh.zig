const std = @import("std");

const raw_mesh = @import("raw_mesh.zig");
const RawVertex = raw_mesh.RawVertex;
const RawMesh = raw_mesh.RawMesh;

pub const FormatFlags = packed struct {
    has_normals: bool = false,
    has_tangents: bool = false,
    has_uv0: bool = false,
    has_uv1: bool = false,
    has_joints: bool = false,
    has_weights: bool = false,
    _padding: u2 = 0, // pad to u8
};

pub const CookedVertex = struct {
    position: [3]f32,
    normal: ?[3]i16,
    tangent: ?[4]f16,
    uv0: ?[2]u16,
    uv1: ?[2]u16,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f16,

    pub fn cook(vertex: *const RawVertex) !CookedVertex {
        return .{
            .position = vertex.position,
            .normal = vertex.encodeNormalOctahedral(),
            .tangent = vertex.quantizeTangent(),
            .uv0 = vertex.quantizeUV0(),
            .uv1 = vertex.quantizeUV1(),
            .joint_indices = vertex.joint_indices,
            .joint_weights = vertex.quantizeJointWeights(),
        };
    }
};

pub const AABB = struct {
    min: [3]f32,
    max: [3]f32,
};

pub const IndexFormat = enum {
    u16,
    u32,
};

pub const IndexBuffer = struct {
    u16: ?[]u16,
    u32: ?[]u32,

    pub fn format(self: *const IndexBuffer) IndexFormat {
        if (self.u16 != null) return .u16;
        return .u32;
    }

    pub fn compute(allocator: std.mem.Allocator, raw_indices: []const u32, vertex_count: usize) !IndexBuffer {
        if (vertex_count <= std.math.maxInt(u16)) {
            const idx = try allocator.alloc(u16, raw_indices.len);
            for (raw_indices, idx) |src, *dst| {
                dst.* = @intCast(src);
            }
            return .{ .u16 = idx, .u32 = null };
        } else {
            return .{ .u16 = null, .u32 = try allocator.dupe(u32, raw_indices) };
        }
    }

    pub fn deinit(self: *IndexBuffer, allocator: std.mem.Allocator) void {
        if (self.u16) |idx| allocator.free(idx);
        if (self.u32) |idx| allocator.free(idx);
    }
};

pub const CookedMesh = struct {
    vertices: []CookedVertex,
    indices: IndexBuffer,
    submeshes: []raw_mesh.RawSubmesh,
    format_flags: FormatFlags,
    bounds: AABB,
    name: ?[]const u8,

    pub fn deinit(self: *CookedMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        self.indices.deinit(allocator);
    }

    pub fn cook(allocator: std.mem.Allocator, mesh: *RawMesh) !CookedMesh {
        // Run optimizations on raw mesh
        try mesh.optimize(allocator);

        // Determine format flags from first vertex
        const flags: FormatFlags = if (mesh.vertices.len > 0) .{
            .has_normals = mesh.vertices[0].normal != null,
            .has_tangents = mesh.vertices[0].tangent != null,
            .has_uv0 = mesh.vertices[0].uv0 != null,
            .has_uv1 = mesh.vertices[0].uv1 != null,
            .has_joints = mesh.vertices[0].joint_indices != null,
            .has_weights = mesh.vertices[0].joint_weights != null,
        } else .{};

        // Cook vertices and compute AABB
        const cooked_verts = try allocator.alloc(CookedVertex, mesh.vertices.len);
        errdefer allocator.free(cooked_verts);

        var bounds = AABB{
            .min = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
            .max = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
        };

        for (mesh.vertices, cooked_verts) |*raw_vert, *cooked| {
            cooked.* = try CookedVertex.cook(raw_vert);

            for (0..3) |axis| {
                bounds.min[axis] = @min(bounds.min[axis], raw_vert.position[axis]);
                bounds.max[axis] = @max(bounds.max[axis], raw_vert.position[axis]);
            }
        }

        const indices = try IndexBuffer.compute(allocator, mesh.indices, mesh.vertices.len);

        return .{
            .vertices = cooked_verts,
            .indices = indices,
            .submeshes = mesh.submeshes,
            .format_flags = flags,
            .bounds = bounds,
            .name = mesh.name,
        };
    }
};
