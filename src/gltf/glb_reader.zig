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

const GLBChunkHeader = struct {
    length: u32,
    type: u32,
};

pub const GLBResultError = error{
    FileToSmall,
    InvalidMagic,
    InvalidVersion,
    LengthMismatch,
    OutOfMemory,
};

inline fn processStruct(comptime T: type, file_bytes: []const u8, start: usize) T {
    return std.mem.bytesAsValue(T, file_bytes[start..][0..@sizeOf(T)]).*;
}

pub const GLBFile = struct {
    json: []const u8,
    bin: []const u8,

    pub fn parse(allocator: std.mem.Allocator, file_bytes: []const u8) GLBResultError!*GLBFile {
        if (file_bytes.len < @sizeOf(GLBHeader)) {
            return GLBResultError.FileToSmall;
        }

        const header = processStruct(GLBHeader, file_bytes, 0);
        if (header.magic != GLB_MAGIC) {
            return GLBResultError.InvalidMagic;
        }

        if (header.version != GLB_VERSION) {
            return GLBResultError.InvalidVersion;
        }

        if (header.length != file_bytes.len) {
            return GLBResultError.LengthMismatch;
        }

        const json_header = processStruct(GLBChunkHeader, file_bytes, @sizeOf(GLBHeader));
        if (json_header.type != JSON_CHUNK) {
            return GLBResultError.InvalidMagic;
        }

        const json_bytes = file_bytes[@sizeOf(GLBHeader) + @sizeOf(GLBChunkHeader) ..][0..json_header.length];

        const bin_start = @sizeOf(GLBHeader) + @sizeOf(GLBChunkHeader) + json_header.length;
        const bin_header = processStruct(GLBChunkHeader, file_bytes, bin_start);
        if (bin_header.type != BIN_CHUNK) {
            return GLBResultError.InvalidMagic;
        }

        const bin_bytes = file_bytes[bin_start + @sizeOf(GLBChunkHeader) ..][0..bin_header.length];

        const file = try allocator.create(GLBFile);
        file.* = GLBFile{
            .json = json_bytes,
            .bin = bin_bytes,
        };

        return file;
    }
};
