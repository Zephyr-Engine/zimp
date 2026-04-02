const std = @import("std");

const GLB_VERSION = 2;
const GLB_MAGIC = 0x46546C67; // ASCII for 'glTF'
const JSON_CHUNK = 0x4E4F534A; // ASCII for 'JSON'
const BIN_CHUNK = 0x004E4942; // ASCII for 'BIN\0'

const GLBHeader = struct {
    magic: u32,
    version: u32,
    length: u32,
};

const GLBChunk = struct {
    length: u32,
    type: u32,
    data: []const u8,
};

pub const GLBResultError = error{
    FileToSmall,
    InvalidMagic,
    InvalidVersion,
    OutOfMemory,
};

pub const GLBFile = struct {
    json: []const u8,
    bin: []const u8,

    pub fn parse(allocator: std.mem.Allocator, file_bytes: []const u8) GLBResultError!*GLBFile {
        if (file_bytes.len < @sizeOf(GLBHeader)) {
            return GLBResultError.FileToSmall;
        }

        const header = @as(*const GLBHeader, @ptrCast(@alignCast(file_bytes[0..@sizeOf(GLBHeader)])));
        if (header.magic != GLB_MAGIC) {
            return GLBResultError.InvalidMagic;
        }

        if (header.version != GLB_VERSION) {
            return GLBResultError.InvalidVersion;
        }

        const file = try allocator.create(GLBFile);
        return file;
    }
};
