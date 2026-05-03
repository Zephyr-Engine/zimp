const std = @import("std");

const log = @import("../logger.zig");
const fmt = @import("utils.zig");
const FormatInspector = @import("inspect.zig").FormatInspector;
const zamat = @import("../formats/zamat.zig");

fn alphaModeName(mode: zamat.AlphaMode) []const u8 {
    return switch (mode) {
        .solid => "solid",
        .alpha_test => "alpha_test",
        .alpha_blend => "alpha_blend",
    };
}

fn paramTypeName(param_type: zamat.ParamType) []const u8 {
    return switch (param_type) {
        .float => "float",
        .vec2 => "vec2",
        .vec3 => "vec3",
        .vec4 => "vec4",
        .int => "int",
        .bool => "bool",
    };
}

fn inspectZamat(allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
    _ = allocator;
    const header = try zamat.ZamatHeader.read(reader);

    log.info("zamat v{d}", .{zamat.ZAMAT_VERSION});
    log.info("  Magic:       {s}", .{zamat.MAGIC});
    log.info("  Version:     {d}", .{header.version});
    log.info("  Shader hash: 0x{x:0>16}", .{header.shader_path_hash});
    log.info("  Alpha mode:  {s}", .{alphaModeName(header.alpha_mode)});
    log.info("  Textures:    {d}", .{header.texture_slot_count});
    log.info("  Params:      {d}", .{header.param_count});

    var texture_entries: [32]zamat.TextureSlotEntry = undefined;
    if (header.texture_slot_count > texture_entries.len) return error.TooManyTextureSlots;
    var runtime_paths_len = @max(
        @as(usize, header.vertex_shader_path_offset) + header.vertex_shader_path_len,
        @as(usize, header.fragment_shader_path_offset) + header.fragment_shader_path_len,
    );
    for (0..header.texture_slot_count) |i| {
        texture_entries[i] = .{
            .slot_name_hash = try reader.takeInt(u64, .little),
            .texture_path_hash = try reader.takeInt(u64, .little),
            .slot_index = try reader.takeInt(u16, .little),
            .cooked_path = undefined,
            .cooked_path_offset = try reader.takeInt(u16, .little),
            .cooked_path_len = try reader.takeInt(u16, .little),
        };
        _ = try reader.takeInt(u16, .little);
        const cooked_path_end = @as(usize, texture_entries[i].cooked_path_offset) + texture_entries[i].cooked_path_len;
        if (cooked_path_end > runtime_paths_len) runtime_paths_len = cooked_path_end;
    }

    var entries: [64]zamat.ParamEntry = undefined;
    if (header.param_count > entries.len) return error.TooManyParams;

    log.info("", .{});
    log.info("Params:", .{});
    log.info("  {s: >5}  {s: <24}  {s: <8}  {s: >8}  {s: >8}  {s}", .{ "index", "name", "type", "offset", "size", "value" });
    log.info("  {s}", .{"-" ** 78});

    var param_data_len: usize = 0;
    var param_name_len: usize = 0;
    for (0..header.param_count) |i| {
        entries[i] = .{
            .name = undefined,
            .name_offset = try reader.takeInt(u16, .little),
            .name_len = try reader.takeInt(u16, .little),
            .param_type = @enumFromInt(try reader.takeInt(u16, .little)),
            .data_offset = try reader.takeInt(u16, .little),
            .data_size = try reader.takeInt(u16, .little),
        };
        _ = try reader.takeInt(u16, .little);

        const end = @as(usize, entries[i].data_offset) + entries[i].data_size;
        if (end > param_data_len) param_data_len = end;
        const name_end = @as(usize, entries[i].name_offset) + entries[i].name_len;
        if (name_end > param_name_len) param_name_len = name_end;
    }

    var param_data_buf: [4096]u8 = undefined;
    if (param_data_len > param_data_buf.len) return error.ParamDataTooLarge;
    const param_data = param_data_buf[0..param_data_len];
    try reader.readSliceAll(param_data);

    var param_name_buf: [4096]u8 = undefined;
    if (param_name_len > param_name_buf.len) return error.ParamNamesTooLarge;
    const param_names = param_name_buf[0..param_name_len];
    try reader.readSliceAll(param_names);

    var runtime_path_buf: [4096]u8 = undefined;
    if (runtime_paths_len > runtime_path_buf.len) return error.RuntimePathsTooLarge;
    const runtime_paths = runtime_path_buf[0..runtime_paths_len];
    try reader.readSliceAll(runtime_paths);

    log.info("", .{});
    log.info("Shader Paths:", .{});
    log.info("  Vertex:   {s}", .{runtime_paths[header.vertex_shader_path_offset..][0..header.vertex_shader_path_len]});
    log.info("  Fragment: {s}", .{runtime_paths[header.fragment_shader_path_offset..][0..header.fragment_shader_path_len]});

    log.info("", .{});
    log.info("Texture Slots:", .{});
    log.info("  {s: >5}  {s: >18}  {s: >18}  {s: >10}  {s}", .{ "index", "slot_hash", "texture_hash", "slot_unit", "cooked_path" });
    log.info("  {s}", .{"-" ** 86});
    for (0..header.texture_slot_count) |i| {
        var entry = texture_entries[i];
        entry.cooked_path = runtime_paths[entry.cooked_path_offset..][0..entry.cooked_path_len];
        log.info("  {d: >5}  0x{x:0>16}  0x{x:0>16}  {d: >10}  {s}", .{
            i,
            entry.slot_name_hash,
            entry.texture_path_hash,
            entry.slot_index,
            entry.cooked_path,
        });
    }

    for (0..header.param_count) |i| {
        var entry = entries[i];
        entry.name = param_names[entry.name_offset..][0..entry.name_len];
        var value_buf: [96]u8 = undefined;
        log.info("  {d: >5}  {s: <24}  {s: <8}  {d: >8}  {d: >8}  {s}", .{
            i,
            entry.name,
            paramTypeName(entry.param_type),
            entry.data_offset,
            entry.data_size,
            formatParamValue(&value_buf, param_data, entry),
        });
    }

    log.info("", .{});
    var header_buf: [16]u8 = undefined;
    var texture_buf: [16]u8 = undefined;
    var param_buf: [16]u8 = undefined;
    var data_buf: [16]u8 = undefined;
    var name_buf: [16]u8 = undefined;
    var runtime_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    const texture_table_size = @as(u64, @intCast(header.texture_slot_count)) * zamat.TEXTURE_SLOT_ENTRY_SIZE;
    const param_table_size = @as(u64, @intCast(header.param_count)) * zamat.PARAM_ENTRY_SIZE;
    const total_file_size = zamat.HEADER_SIZE + texture_table_size + param_table_size + param_data_len + param_name_len + runtime_paths_len;
    log.info("File Size Summary:", .{});
    log.info("  Header:         {s: >10}", .{fmt.formatBytes(&header_buf, zamat.HEADER_SIZE)});
    log.info("  Texture table:  {s: >10}", .{fmt.formatBytes(&texture_buf, texture_table_size)});
    log.info("  Param table:    {s: >10}", .{fmt.formatBytes(&param_buf, param_table_size)});
    log.info("  Param data:     {s: >10}", .{fmt.formatBytes(&data_buf, param_data_len)});
    log.info("  Param names:    {s: >10}", .{fmt.formatBytes(&name_buf, param_name_len)});
    log.info("  Runtime paths:  {s: >10}", .{fmt.formatBytes(&runtime_buf, runtime_paths_len)});
    log.info("  Total:          {s: >10}", .{fmt.formatBytes(&total_buf, total_file_size)});
}

fn formatParamValue(buf: []u8, data: []const u8, entry: zamat.ParamEntry) []const u8 {
    const start: usize = entry.data_offset;
    const end = @as(usize, start) + entry.data_size;
    if (end > data.len) return "(out of bounds)";
    const bytes = data[start..end];

    return switch (entry.param_type) {
        .float => std.fmt.bufPrint(buf, "{d}", .{readF32(bytes[0..4])}) catch "(format error)",
        .vec2 => std.fmt.bufPrint(buf, "[{d}, {d}]", .{ readF32(bytes[0..4]), readF32(bytes[4..8]) }) catch "(format error)",
        .vec3 => std.fmt.bufPrint(buf, "[{d}, {d}, {d}]", .{ readF32(bytes[0..4]), readF32(bytes[4..8]), readF32(bytes[8..12]) }) catch "(format error)",
        .vec4 => std.fmt.bufPrint(buf, "[{d}, {d}, {d}, {d}]", .{ readF32(bytes[0..4]), readF32(bytes[4..8]), readF32(bytes[8..12]), readF32(bytes[12..16]) }) catch "(format error)",
        .int => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(i32, bytes[0..4], .little)}) catch "(format error)",
        .bool => std.fmt.bufPrint(buf, "{s}", .{if (std.mem.readInt(u32, bytes[0..4], .little) != 0) "true" else "false"}) catch "(format error)",
    };
}

fn readF32(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}

pub fn inspector() FormatInspector {
    return .{ .inspectFn = inspectZamat };
}

const testing = std.testing;
const raw_material = @import("../assets/raw/material.zig");
const CookedMaterial = @import("../assets/cooked/material.zig").CookedMaterial;

test "inspector returns a valid FormatInspector" {
    const insp = inspector();
    try testing.expectEqual(@as(*const fn (std.mem.Allocator, *std.Io.Reader) anyerror!void, inspectZamat), insp.inspectFn);
}

test "inspectZamat runs on a valid material file" {
    var parsed = try raw_material.parseMaterialSource(
        \\[material]
        \\shader = "shaders/basic"
        \\[textures]
        \\albedo = "textures/test_albedo.png"
        \\[params]
        \\u_roughness = 0.5
        \\
    , testing.allocator);
    defer parsed.deinit(testing.allocator);

    var cooked = try CookedMaterial.cook(testing.allocator, &parsed);
    defer cooked.deinit(testing.allocator);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try zamat.write(&writer, cooked);

    var reader = std.Io.Reader.fixed(buf[zamat.MAGIC.len..writer.end]);
    try inspectZamat(testing.allocator, &reader);
}
