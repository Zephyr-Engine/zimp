const std = @import("std");

const asset = @import("asset.zig");

pub const SourceFile = struct {
    path: []const u8,
    extension: asset.Extension,
    assetType: asset.AssetType,

    pub fn hash(self: SourceFile, io: std.Io) !u64 {
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(io, self.path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        const fr = file.reader(io, &buf);
        var reader = &fr.interface;

        var hash_buf: [4096]u8 = undefined;
        var hr = reader.hashed(std.hash.XxHash64.init(0), &hash_buf);
        _ = try hr.reader.discardRemaining();

        return hr.hasher.final();
    }
};
