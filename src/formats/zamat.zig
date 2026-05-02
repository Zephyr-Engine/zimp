const std = @import("std");

const constants = @import("../shared/constants.zig");
const cooked_material = @import("../assets/cooked/material.zig");
const raw_material = @import("../assets/raw/material.zig");
const file_read = @import("../shared/file_read.zig");

pub const MAGIC = constants.FORMAT_MAGIC.ZAMAT;
pub const ZAMAT_VERSION: u32 = 1;

pub const AlphaMode = cooked_material.AlphaMode;
pub const TextureSlotEntry = cooked_material.TextureSlotEntry;
pub const ParamEntry = cooked_material.ParamEntry;
pub const ParamType = cooked_material.ParamType;
pub const CookedMaterial = cooked_material.CookedMaterial;

pub const TEXTURE_SLOT_ENTRY_SIZE: u32 = @sizeOf(u64) // slot_name_hash
+ @sizeOf(u64) // texture_path_hash
+ @sizeOf(u16) // slot_index
+ @sizeOf(u16); // padding

pub const PARAM_ENTRY_SIZE: u32 = @sizeOf(u64) // name_hash
+ @sizeOf(u16) // param_type
+ @sizeOf(u16) // data_offset
+ @sizeOf(u16) // data_size
+ @sizeOf(u16); // padding

pub const HEADER_SIZE: u32 = MAGIC.len // magic
+ @sizeOf(u32) // version
+ @sizeOf(u64) // shader_path_hash
+ @sizeOf(u16) // alpha_mode
+ @sizeOf(u16) // texture_slot_count
+ @sizeOf(u16) // param_count
+ @sizeOf(u16) // padding
+ @sizeOf(u32) // texture_table_offset
+ @sizeOf(u32) // param_table_offset
+ @sizeOf(u32); // param_data_offset

pub const ZamatHeader = struct {
    magic: [MAGIC.len]u8 = MAGIC.*,
    version: u32 = ZAMAT_VERSION,
    shader_path_hash: u64,
    alpha_mode: AlphaMode,
    texture_slot_count: u16,
    param_count: u16,
    texture_table_offset: u32,
    param_table_offset: u32,
    param_data_offset: u32,

    pub fn init(material: CookedMaterial) !ZamatHeader {
        if (material.texture_slots.len > std.math.maxInt(u16)) return error.TooManyTextureSlots;
        if (material.param_entries.len > std.math.maxInt(u16)) return error.TooManyParams;

        const texture_table_offset = HEADER_SIZE;
        const param_table_offset = texture_table_offset + @as(u32, @intCast(material.texture_slots.len)) * TEXTURE_SLOT_ENTRY_SIZE;
        const param_data_offset = param_table_offset + @as(u32, @intCast(material.param_entries.len)) * PARAM_ENTRY_SIZE;

        return .{
            .shader_path_hash = material.shader_path_hash,
            .alpha_mode = material.alpha_mode,
            .texture_slot_count = @intCast(material.texture_slots.len),
            .param_count = @intCast(material.param_entries.len),
            .texture_table_offset = texture_table_offset,
            .param_table_offset = param_table_offset,
            .param_data_offset = param_data_offset,
        };
    }

    pub fn read(reader: *std.Io.Reader) !ZamatHeader {
        const version = try reader.takeInt(u32, .little);
        if (version != ZAMAT_VERSION) return error.UnsupportedVersion;

        const shader_path_hash = try reader.takeInt(u64, .little);
        const alpha_mode: AlphaMode = @enumFromInt(try reader.takeInt(u16, .little));
        const texture_slot_count = try reader.takeInt(u16, .little);
        const param_count = try reader.takeInt(u16, .little);
        _ = try reader.takeInt(u16, .little);
        const texture_table_offset = try reader.takeInt(u32, .little);
        const param_table_offset = try reader.takeInt(u32, .little);
        const param_data_offset = try reader.takeInt(u32, .little);

        if (texture_slot_count > 32) return error.TooManyTextureSlots;
        if (param_count > 64) return error.TooManyParams;

        return .{
            .shader_path_hash = shader_path_hash,
            .alpha_mode = alpha_mode,
            .texture_slot_count = texture_slot_count,
            .param_count = param_count,
            .texture_table_offset = texture_table_offset,
            .param_table_offset = param_table_offset,
            .param_data_offset = param_data_offset,
        };
    }

    pub fn write(self: *const ZamatHeader, writer: *std.Io.Writer) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u32, self.version, .little);
        try writer.writeInt(u64, self.shader_path_hash, .little);
        try writer.writeInt(u16, @intFromEnum(self.alpha_mode), .little);
        try writer.writeInt(u16, self.texture_slot_count, .little);
        try writer.writeInt(u16, self.param_count, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, self.texture_table_offset, .little);
        try writer.writeInt(u32, self.param_table_offset, .little);
        try writer.writeInt(u32, self.param_data_offset, .little);
    }
};

pub const Zamat = struct {
    shader_path_hash: u64,
    alpha_mode: AlphaMode,
    texture_slots: []TextureSlotEntry,
    param_entries: []ParamEntry,
    param_data: []u8,

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Zamat {
        var magic: [MAGIC.len]u8 = undefined;
        try reader.readSliceAll(&magic);
        if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidMagic;

        const header = try ZamatHeader.read(reader);
        const texture_slots = try readTextureSlots(allocator, reader, header.texture_slot_count);
        errdefer allocator.free(texture_slots);
        const param_entries = try readParamEntries(allocator, reader, header.param_count);
        errdefer allocator.free(param_entries);

        var param_data: std.ArrayList(u8) = .empty;
        errdefer param_data.deinit(allocator);
        for (param_entries) |entry| {
            const end = @as(usize, entry.data_offset) + entry.data_size;
            if (end > param_data.items.len) {
                try param_data.resize(allocator, end);
            }
        }
        try reader.readSliceAll(param_data.items);

        return .{
            .shader_path_hash = header.shader_path_hash,
            .alpha_mode = header.alpha_mode,
            .texture_slots = texture_slots,
            .param_entries = param_entries,
            .param_data = try param_data.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Zamat, allocator: std.mem.Allocator) void {
        allocator.free(self.texture_slots);
        allocator.free(self.param_entries);
        allocator.free(self.param_data);
    }
};

pub const Material = struct {
    shader_path_hash: u64,
    alpha_mode: AlphaMode,
    texture_slots: []TextureSlotEntry,
    param_entries: []ParamEntry,
    param_data: []u8,
    file_bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Material) void {
        self.allocator.free(self.texture_slots);
        self.allocator.free(self.param_entries);
        self.allocator.free(self.param_data);
        self.allocator.free(self.file_bytes);
    }
};

pub fn loadMaterial(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Material {
    const file_result = try file_read.readFileAllocChunked(allocator, io, dir, path, .{
        .chunk_size = 256 * 1024,
    });
    errdefer allocator.free(file_result.bytes);

    var reader = std.Io.Reader.fixed(file_result.bytes);
    var z = try Zamat.read(allocator, &reader);
    errdefer z.deinit(allocator);

    return .{
        .shader_path_hash = z.shader_path_hash,
        .alpha_mode = z.alpha_mode,
        .texture_slots = z.texture_slots,
        .param_entries = z.param_entries,
        .param_data = z.param_data,
        .file_bytes = file_result.bytes,
        .allocator = allocator,
    };
}

pub fn write(writer: *std.Io.Writer, material: CookedMaterial) !void {
    const header = try ZamatHeader.init(material);
    try header.write(writer);

    for (material.texture_slots) |entry| {
        try writer.writeInt(u64, entry.slot_name_hash, .little);
        try writer.writeInt(u64, entry.texture_path_hash, .little);
        try writer.writeInt(u16, entry.slot_index, .little);
        try writer.writeInt(u16, 0, .little);
    }

    for (material.param_entries) |entry| {
        try writer.writeInt(u64, entry.name_hash, .little);
        try writer.writeInt(u16, @intFromEnum(entry.param_type), .little);
        try writer.writeInt(u16, entry.data_offset, .little);
        try writer.writeInt(u16, entry.data_size, .little);
        try writer.writeInt(u16, 0, .little);
    }

    try writer.writeAll(material.param_data);
}

pub fn writeZamat(writer: *std.Io.Writer, material_source: raw_material.MaterialSource, allocator: std.mem.Allocator) !void {
    var cooked = try CookedMaterial.cook(allocator, &material_source);
    defer cooked.deinit(allocator);
    try write(writer, cooked);
}

fn readTextureSlots(allocator: std.mem.Allocator, reader: *std.Io.Reader, count: usize) ![]TextureSlotEntry {
    const entries = try allocator.alloc(TextureSlotEntry, count);
    errdefer allocator.free(entries);

    for (entries) |*entry| {
        entry.* = .{
            .slot_name_hash = try reader.takeInt(u64, .little),
            .texture_path_hash = try reader.takeInt(u64, .little),
            .slot_index = try reader.takeInt(u16, .little),
        };
        _ = try reader.takeInt(u16, .little);
    }

    return entries;
}

fn readParamEntries(allocator: std.mem.Allocator, reader: *std.Io.Reader, count: usize) ![]ParamEntry {
    const entries = try allocator.alloc(ParamEntry, count);
    errdefer allocator.free(entries);

    for (entries) |*entry| {
        entry.* = .{
            .name_hash = try reader.takeInt(u64, .little),
            .param_type = @enumFromInt(try reader.takeInt(u16, .little)),
            .data_offset = try reader.takeInt(u16, .little),
            .data_size = try reader.takeInt(u16, .little),
        };
        _ = try reader.takeInt(u16, .little);
    }

    return entries;
}

const testing = std.testing;
const fnv1a = @import("../assets/source_file.zig").fnv1a;

fn cookedFromSource(source_text: []const u8) !CookedMaterial {
    var parsed = try raw_material.parseMaterialSource(source_text, testing.allocator);
    defer parsed.deinit(testing.allocator);
    return CookedMaterial.cook(testing.allocator, &parsed);
}

test "Zamat write lays out offsets and size" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[textures]
        \\albedo = "textures/test_albedo.png"
        \\normal = "textures/test_normal.png"
        \\[params]
        \\u_roughness = 0.5
        \\u_light_dir = [0.5, 1.0, 0.3]
        \\u_light_color = [1.0, 0.95, 0.9]
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);

    try testing.expectEqual(@as(usize, HEADER_SIZE + 2 * TEXTURE_SLOT_ENTRY_SIZE + 3 * PARAM_ENTRY_SIZE + 28), writer.end);
    try testing.expectEqualSlices(u8, MAGIC, buf[0..MAGIC.len]);

    var reader = std.Io.Reader.fixed(buf[MAGIC.len..writer.end]);
    const header = try ZamatHeader.read(&reader);
    try testing.expectEqual(@as(u32, HEADER_SIZE), header.texture_table_offset);
    try testing.expectEqual(@as(u32, HEADER_SIZE + 2 * TEXTURE_SLOT_ENTRY_SIZE), header.param_table_offset);
    try testing.expectEqual(@as(u32, HEADER_SIZE + 2 * TEXTURE_SLOT_ENTRY_SIZE + 3 * PARAM_ENTRY_SIZE), header.param_data_offset);
}

test "Zamat write and read round trips" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\alpha_mode = "alpha_test"
        \\[textures]
        \\albedo = "textures/test_albedo.png"
        \\[params]
        \\u_enabled = true
        \\u_mode = 2
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);

    var reader = std.Io.Reader.fixed(buf[0..writer.end]);
    var loaded = try Zamat.read(testing.allocator, &reader);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(fnv1a("shaders/basic"), loaded.shader_path_hash);
    try testing.expectEqual(AlphaMode.alpha_test, loaded.alpha_mode);
    try testing.expectEqual(@as(usize, 1), loaded.texture_slots.len);
    try testing.expectEqual(fnv1a("albedo"), loaded.texture_slots[0].slot_name_hash);
    try testing.expectEqual(fnv1a("textures/test_albedo.png"), loaded.texture_slots[0].texture_path_hash);
    try testing.expectEqual(@as(usize, 2), loaded.param_entries.len);
    try testing.expectEqual(@as(usize, 8), loaded.param_data.len);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, loaded.param_data[0..4], .little));
    try testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, loaded.param_data[4..8], .little));
}

test "Zamat supports empty texture and param tables" {
    var cooked = try cookedFromSource(
        \\[material]
        \\shader = "shaders/basic"
        \\
    );
    defer cooked.deinit(testing.allocator);

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try write(&writer, cooked);

    try testing.expectEqual(@as(usize, HEADER_SIZE), writer.end);
}
