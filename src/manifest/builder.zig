const std = @import("std");
const model = @import("model.zig");
const meta_store_mod = @import("meta_store.zig");
const derive = @import("derive.zig");
const kind_mod = @import("kind.zig");
const Cache = @import("../cache/cache.zig").Cache;
const CacheEntry = @import("../cache/entry.zig").CacheEntry;
const AssetId = @import("../id/id_types.zig").AssetId;
const ProjectId = @import("../id/id_types.zig").ProjectId;
const log = @import("../logger.zig");

pub const generated_prefix = "generated/";

pub const BuildInputs = struct {
    project_id: ProjectId,
    /// Post-cook cache (in memory). The manifest never reads `.zcache` from
    /// disk.
    cache: *const Cache,
    metas: *meta_store_mod.MetaStore,
    io: std.Io,
    random: std.Random,
};

pub const BuildStats = struct {
    entries: usize = 0,
    ids_from_sidecar: usize = 0,
    ids_derived: usize = 0,
    ids_new: usize = 0,
    skipped_errored: usize = 0,
    skipped_unknown_kind: usize = 0,
};

/// Build a validated manifest from the post-cook cache, resolving each
/// asset's durable identity via the three rules (generated-derived >
/// sidecar > fresh v4). Sidecars are recorded in `inputs.metas` but NOT
/// flushed here — the caller flushes only after the manifest was written.
pub fn build(gpa: std.mem.Allocator, inputs: BuildInputs, stats: *BuildStats) !model.AssetManifest {
    var m = model.AssetManifest{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_id = inputs.project_id,
        .entries = &.{},
    };
    errdefer m.deinit();
    const a = m.arena.allocator();

    var entries: std.ArrayList(model.AssetManifestEntry) = .empty;

    for (inputs.cache.entries.items) |*cache_entry| {
        if (cache_entry.isErrored()) {
            stats.skipped_errored += 1;
            continue;
        }
        const kind = kind_mod.AssetKind.fromAssetType(cache_entry.asset_type) orelse {
            stats.skipped_unknown_kind += 1; // dependency-only files
            continue;
        };
        try entries.append(a, try buildEntry(a, inputs, stats, cache_entry, kind));
    }

    // Determinism: sort by source_path.
    std.mem.sort(model.AssetManifestEntry, entries.items, {}, entryLessThan);
    m.entries = try entries.toOwnedSlice(a);

    try reportDuplicateIds(gpa, &m);
    try m.validate();
    stats.entries = m.entries.len;
    return m;
}

fn entryLessThan(_: void, lhs: model.AssetManifestEntry, rhs: model.AssetManifestEntry) bool {
    return std.mem.order(u8, lhs.source_path, rhs.source_path) == .lt;
}

/// The three-rule durable-id assignment. Order matters and is frozen:
/// generated paths are derived (never sidecar'd), then an existing sidecar
/// wins, then a fresh v4 is minted and persisted as a sidecar.
fn resolveId(
    inputs: BuildInputs,
    stats: *BuildStats,
    source_path: []const u8,
) !AssetId {
    // Rule 1: generated files never have sidecars; identity is a pure
    // function of the source path.
    if (std.mem.startsWith(u8, source_path, generated_prefix)) {
        stats.ids_derived += 1;
        return derive.generatedAssetId(source_path);
    }

    // Rule 2: sidecar wins.
    if (try inputs.metas.load(source_path)) |meta| {
        stats.ids_from_sidecar += 1;
        return meta.id;
    }

    // Rule 3: brand new asset.
    var id = AssetId.v4(inputs.random);
    while (id.isZero()) id = AssetId.v4(inputs.random);
    stats.ids_new += 1;
    try inputs.metas.create(source_path, .{ .id = id });
    return id;
}

fn buildEntry(
    a: std.mem.Allocator,
    inputs: BuildInputs,
    stats: *BuildStats,
    cache_entry: *const CacheEntry,
    kind: kind_mod.AssetKind,
) !model.AssetManifestEntry {
    const id = try resolveId(inputs, stats, cache_entry.source_path);

    return .{
        .id = id,
        .kind = kind,
        .source_path = try a.dupe(u8, cache_entry.source_path),
        .cooked_path = try a.dupe(u8, cache_entry.cooked_path),
        .content_hash = cache_entry.content_hash,
        .source_size = cache_entry.source_size,
        .cooked_size = cache_entry.cooked_size,
        .generated = std.mem.startsWith(u8, cache_entry.source_path, generated_prefix),
    };
}

/// Duplicate ids (e.g. a file copied together with its sidecar) are a hard
/// error; unlike `validate()` this names both offending paths so the fix is
/// obvious.
fn reportDuplicateIds(gpa: std.mem.Allocator, m: *const model.AssetManifest) !void {
    var seen = std.AutoHashMap(AssetId, []const u8).init(gpa);
    defer seen.deinit();

    for (m.entries) |entry| {
        const gop = try seen.getOrPut(entry.id);
        if (gop.found_existing) {
            log.err("duplicate asset id {s}: '{s}' and '{s}'. " ++
                "If a file was copied together with its .zmeta sidecar, delete the copy's sidecar to mint a fresh id.", .{
                &entry.id.toString(),
                gop.value_ptr.*,
                entry.source_path,
            });
            return error.DuplicateAssetId;
        }
        gop.value_ptr.* = entry.source_path;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const codec = @import("codec.zig");

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    cache: Cache,
    metas: meta_store_mod.MetaStore,

    fn init() !TestFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const cache = try Cache.init(testing.allocator, tmp.dir, "cooked");
        return .{
            .tmp = tmp,
            .cache = cache,
            .metas = meta_store_mod.MetaStore.init(testing.allocator, testing.io, tmp.dir),
        };
    }

    fn deinit(self: *TestFixture) void {
        self.metas.deinit();
        self.cache.deinit(testing.allocator);
        self.tmp.cleanup();
    }

    fn addCacheEntry(self: *TestFixture, source_path: []const u8, cooked_path: []const u8, asset_type: anytype, flags: u16) !void {
        const fnv1a = @import("../assets/source_file.zig").fnv1a;
        try self.cache.pushCacheEntry(testing.allocator, .{
            .source_path = try testing.allocator.dupe(u8, source_path),
            .source_path_hash = fnv1a(source_path),
            .content_hash = fnv1a(source_path) ^ 0x1234,
            .source_size = 100,
            .source_mtime = 0,
            .cooked_path = try testing.allocator.dupe(u8, cooked_path),
            .cooked_path_hash = fnv1a(cooked_path),
            .cooked_size = 50,
            .cooked_at = 0,
            .flags = flags,
            .asset_type = asset_type,
        });
    }

    fn inputs(self: *TestFixture, random: std.Random) BuildInputs {
        return .{
            .project_id = model.test_project_id,
            .cache = &self.cache,
            .metas = &self.metas,
            .io = testing.io,
            .random = random,
        };
    }
};

test "build over an empty cache yields an empty valid manifest" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var prng = std.Random.DefaultPrng.init(0);

    var stats = BuildStats{};
    var m = try build(testing.allocator, fx.inputs(prng.random()), &stats);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.entries.len);
    try testing.expectEqual(@as(usize, 0), stats.entries);
}

test "fresh assets get v4 ids and sidecars; errored and unknown entries are skipped" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var prng = std.Random.DefaultPrng.init(7);

    try fx.tmp.dir.createDirPath(testing.io, "meshes");
    try fx.addCacheEntry("meshes/monkey.glb", "meshes/monkey.zmesh", .mesh, 0);
    try fx.addCacheEntry("tex/broken.png", "tex/broken.zatex", .texture, @import("../cache/entry.zig").FLAG_ERRORED);
    try fx.addCacheEntry("includes/common.glsl", "includes/common.glsl", .unknown, 0);

    var stats = BuildStats{};
    var m = try build(testing.allocator, fx.inputs(prng.random()), &stats);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqual(@as(usize, 1), stats.ids_new);
    try testing.expectEqual(@as(usize, 1), stats.skipped_errored);
    try testing.expectEqual(@as(usize, 1), stats.skipped_unknown_kind);

    const entry = m.findBySourcePath("meshes/monkey.glb").?;
    try testing.expect(!entry.id.isZero());
    try testing.expect(!entry.generated);

    // Sidecar recorded and flushable.
    try testing.expectEqual(@as(usize, 1), try fx.metas.flush(testing.allocator));
    const bytes = try fx.tmp.dir.readFileAlloc(testing.io, "meshes/monkey.glb.zmeta", testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, &entry.id.toString()) != null);
}

test "existing sidecar wins and is not rewritten" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var prng = std.Random.DefaultPrng.init(7);

    try fx.tmp.dir.createDirPath(testing.io, "meshes");
    try fx.tmp.dir.writeFile(testing.io, .{
        .sub_path = "meshes/monkey.glb.zmeta",
        .data =
        \\{"format":"zephyr.assetmeta","version":1,"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01"}
        ,
    });
    try fx.addCacheEntry("meshes/monkey.glb", "meshes/monkey.zmesh", .mesh, 0);

    var stats = BuildStats{};
    var m = try build(testing.allocator, fx.inputs(prng.random()), &stats);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), stats.ids_from_sidecar);
    try testing.expect(m.entries[0].id.eql(AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01")));
    try testing.expectEqual(@as(usize, 0), try fx.metas.flush(testing.allocator));
}

test "generated assets get derived ids and no sidecars" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var prng = std.Random.DefaultPrng.init(7);

    try fx.addCacheEntry("generated/materials/m.zamat", "generated/materials/m.zamat", .material, 0);

    var stats = BuildStats{};
    var m = try build(testing.allocator, fx.inputs(prng.random()), &stats);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), stats.ids_derived);
    try testing.expect(m.entries[0].id.eql(derive.generatedAssetId("generated/materials/m.zamat")));
    try testing.expect(m.entries[0].generated);
    try testing.expectEqual(@as(usize, 0), try fx.metas.flush(testing.allocator));
}

test "duplicate sidecar ids are a hard error" {
    var fx = try TestFixture.init();
    defer fx.deinit();
    var prng = std.Random.DefaultPrng.init(7);

    const sidecar =
        \\{"format":"zephyr.assetmeta","version":1,"id":"3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01"}
    ;
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.glb.zmeta", .data = sidecar });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "b.glb.zmeta", .data = sidecar });
    try fx.addCacheEntry("a.glb", "a.zmesh", .mesh, 0);
    try fx.addCacheEntry("b.glb", "b.zmesh", .mesh, 0);

    var stats = BuildStats{};
    try testing.expectError(error.DuplicateAssetId, build(testing.allocator, fx.inputs(prng.random()), &stats));
}

test "rebuild from identical inputs is byte-identical" {
    var fx = try TestFixture.init();
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(testing.io, "meshes");
    try fx.addCacheEntry("meshes/monkey.glb", "meshes/monkey.zmesh", .mesh, 0);
    try fx.addCacheEntry("generated/materials/m.zamat", "generated/materials/m.zamat", .material, 0);

    var prng1 = std.Random.DefaultPrng.init(1);
    var stats1 = BuildStats{};
    var m1 = try build(testing.allocator, fx.inputs(prng1.random()), &stats1);
    defer m1.deinit();
    _ = try fx.metas.flush(testing.allocator);
    const b1 = try codec.encodeAlloc(testing.allocator, &m1);
    defer testing.allocator.free(b1);

    // Second build: fresh MetaStore reading the flushed sidecars, different
    // PRNG seed — ids must come from sidecars/derivation, not randomness.
    var metas2 = meta_store_mod.MetaStore.init(testing.allocator, testing.io, fx.tmp.dir);
    defer metas2.deinit();
    var prng2 = std.Random.DefaultPrng.init(999);
    var inputs2 = fx.inputs(prng2.random());
    inputs2.metas = &metas2;
    var stats2 = BuildStats{};
    var m2 = try build(testing.allocator, inputs2, &stats2);
    defer m2.deinit();
    const b2 = try codec.encodeAlloc(testing.allocator, &m2);
    defer testing.allocator.free(b2);

    try testing.expectEqualStrings(b1, b2);
    try testing.expectEqual(@as(usize, 0), stats2.ids_new);
}
