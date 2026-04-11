const std = @import("std");
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const CacheEntry = @import("entry.zig").CacheEntry;

pub const Staleness = enum {
    cached,
    hash_match,
    stale_size,
    stale_content,
    not_cached,

    pub fn check(io: std.Io, source_dir: std.Io.Dir, cache_entry: *const CacheEntry, source_file: *const SourceFile) !Staleness {
        const source_file_info = try source_file.getFileInfo(source_dir, io);
        if (cache_entry.source_mtime == source_file_info.modified_ns) {
            return .cached;
        }

        if (cache_entry.source_size != source_file_info.size) {
            return .stale_size;
        }

        const source_content_hash = try source_file.hash(source_dir, io);
        if (cache_entry.content_hash != source_content_hash) {
            return .stale_content;
        }

        return .hash_match;
    }
};
