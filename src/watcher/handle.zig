const std = @import("std");

const CookContext = @import("../commands/cook/context.zig").CookContext;
const ProjectRoot = @import("../project/project_root.zig").ProjectRoot;
const watcher_mod = @import("watcher.zig");
const log = @import("../logger.zig");

/// Configuration for polling and debounce behavior.
pub const WatchOptions = watcher_mod.Options;
/// Optional notification invoked after each cook attempt.
pub const Callback = watcher_mod.Callback;
/// The outcome passed to `Callback.on_cook`.
pub const CookResult = watcher_mod.CookResult;
const Watcher = watcher_mod.Watcher;
const WatcherRunResult = @typeInfo(@TypeOf(Watcher.run)).@"fn".return_type.?;

/// Owns a background project watcher. Call `stop` exactly once to cancel the
/// watcher, release its resources, and free the handle.
pub const WatchHandle = @This();

gpa: std.mem.Allocator,
io: std.Io,
project_root: ProjectRoot,
source: std.Io.Dir,
output: std.Io.Dir,
output_path: []const u8,
watcher: Watcher,
future: std.Io.Future(WatcherRunResult),

pub fn stop(self: *WatchHandle) void {
    self.watcher.stop();

    _ = self.future.cancel(self.io) catch {};
    self.watcher.deinit();

    self.source.close(self.io);
    self.output.close(self.io);
    self.gpa.free(self.output_path);
    self.project_root.deinit();

    const gpa = self.gpa;
    gpa.destroy(self);
}

/// Start watching the project rooted at `project_root_path` in the background.
/// The watcher performs an initial cook before waiting for source changes.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    project_root_path: []const u8,
    options: WatchOptions,
    callback: Callback,
) !*WatchHandle {
    const handle = try gpa.create(WatchHandle);
    errdefer gpa.destroy(handle);

    handle.gpa = gpa;
    handle.io = io;

    handle.project_root = ProjectRoot.open(gpa, io, project_root_path) catch |err| {
        log.err("watch: failed to open project '{s}': {s}", .{ project_root_path, @errorName(err) });
        return err;
    };
    errdefer handle.project_root.deinit();
    const pr = &handle.project_root;

    handle.source = try pr.openDir(pr.manifest.assets_dir, .{ .iterate = true });
    errdefer handle.source.close(io);
    handle.output = try pr.makeOpenDir(pr.manifest.cooked_assets_dir);
    errdefer handle.output.close(io);
    handle.output_path = try pr.resolve(gpa, pr.manifest.cooked_assets_dir);
    errdefer gpa.free(handle.output_path);

    const ctx: CookContext = .{
        .io = io,
        .source = handle.source,
        .output = handle.output,
        .output_path = handle.output_path,
        .force = false,
        .project = .{
            .project_id = pr.manifest.project_id,
            .root_dir = pr.root_dir,
            .manifest_path = pr.manifest.asset_manifest,
        },
    };

    handle.watcher = Watcher.init(gpa, io, ctx, options, callback);
    handle.future = try std.Io.concurrent(io, Watcher.run, .{&handle.watcher});

    return handle;
}

const testing = std.testing;
const ProjectManifest = @import("../project/manifest.zig").ProjectManifest;
const ProjectId = @import("../id/id_types.zig").ProjectId;

const TestObserver = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn onCook(ctx: ?*anyopaque, result: watcher_mod.CookResult) void {
        _ = result;
        const self: *TestObserver = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .monotonic);
    }

    fn callback(self: *TestObserver) Callback {
        return .{ .ctx = self, .on_cook = onCook };
    }
};

fn waitForCalls(observer: *const TestObserver, expected: usize) !void {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (observer.calls.load(.acquire) >= expected) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TimedOut;
}

fn testProject(tmp: testing.TmpDir) ![]const u8 {
    const manifest: ProjectManifest = .{
        .project_id = ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    try manifest.save(testing.allocator, testing.io, tmp.dir);
    try tmp.dir.createDirPath(testing.io, "assets");

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(testing.io, ".", &path_buf);
    return testing.allocator.dupe(u8, path_buf[0..path_len]);
}

test "WatchHandle starts an initial cook and creates the output directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_path = try testProject(tmp);
    defer testing.allocator.free(project_path);

    var observer = TestObserver{};
    const handle = try start(testing.allocator, testing.io, project_path, .{
        .poll_interval = .fromMilliseconds(10),
        .debounce = .fromMilliseconds(5),
        .debounce_Max = .fromMilliseconds(100),
    }, observer.callback());

    try waitForCalls(&observer, 1);
    try tmp.dir.access(testing.io, ".zephyr/cooked", .{});

    handle.stop();
}

test "WatchHandle.start rejects a missing project" {
    try testing.expectError(error.ProjectNotFound, start(
        testing.allocator,
        testing.io,
        "definitely-not-a-zimp-project",
        .{},
        .{},
    ));
}

test "WatchHandle.start propagates a missing asset directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest: ProjectManifest = .{
        .project_id = ProjectId.parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    try manifest.save(testing.allocator, testing.io, tmp.dir);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(testing.io, ".", &path_buf);
    const project_path = path_buf[0..path_len];

    try testing.expectError(error.FileNotFound, start(testing.allocator, testing.io, project_path, .{}, .{}));
}
