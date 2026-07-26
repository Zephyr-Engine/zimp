const std = @import("std");

const CountingAllocator = @import("../shared/counting_allocator.zig").CountingAllocator;
const CookContext = @import("../commands/cook/context.zig").CookContext;
const CookMetrics = @import("../commands/cook_metrics.zig").CookMetrics;
const cook_pipeline = @import("../commands/cook/pipeline.zig");
const Snapshot = @import("snapshot.zig");
const wake_mod = @import("wake.zig");
const log = @import("../logger.zig");

pub const Options = struct {
    poll_interval: std.Io.Duration = .fromMilliseconds(500),
    debounce: std.Io.Duration = .fromMilliseconds(250),
    debounce_Max: std.Io.Duration = .fromSeconds(5),
};

pub const CookResult = struct {
    metrics: CookMetrics,
    ok: bool,
};

// optional observer
pub const Callback = struct {
    ctx: ?*anyopaque = null,
    on_cook: ?*const fn (ctx: ?*anyopaque, result: CookResult) void = null,

    fn notify(self: Callback, result: CookResult) void {
        if (self.on_cook) |f| {
            f(self.ctx, result);
        }
    }
};

pub const Watcher = @This();

gpa: std.mem.Allocator,
io: std.Io,
ctx: CookContext,
options: Options,
callback: Callback = .{},
wake: wake_mod.WakeSource,
should_stop: std.atomic.Value(bool) = .init(false),

pub fn init(gpa: std.mem.Allocator, io: std.Io, ctx: CookContext, options: Options, callback: Callback) Watcher {
    return .{
        .gpa = gpa,
        .io = io,
        .ctx = ctx,
        .options = options,
        .callback = callback,
        .wake = wake_mod.WakeSource.init(gpa, io, ctx.source),
    };
}

pub fn deinit(self: *Watcher) void {
    self.wake.deinit();
}

pub fn stop(self: *Watcher) void {
    self.should_stop.store(true, .release);
}

pub fn run(self: *Watcher) !void {
    log.info("watch: watching for changes (poll {f}, debounce {f})", .{
        self.options.poll_interval, self.options.debounce,
    });

    // ensure everything is cooked before we start watching
    self.cook();

    var current = try Snapshot.capture(self.gpa, self.io, self.ctx.source);
    defer current.deinit();

    self.wake.sync(&current);

    while (!self.should_stop.load(.acquire)) {
        switch (self.wake.wait(self.io, self.options.poll_interval)) {
            .canceled => return,
            .timeout, .activity => {},
        }

        if (self.should_stop.load(.acquire)) {
            return;
        }

        var next = try Snapshot.capture(self.gpa, self.io, self.ctx.source);
        if (Snapshot.eql(&current, &next)) {
            next.deinit();
            continue;
        }

        next = self.settle(next) catch |err| switch (err) {
            error.Canceled => return,
            else => return err,
        };

        Snapshot.logDiff(&current, &next);
        current.deinit();
        current = next;

        self.wake.sync(&current);
        self.cook();
    }
}

fn cook(self: *Watcher) void {
    var counting = CountingAllocator.init(self.gpa);

    const metrics = cook_pipeline.run(counting.allocator(), &counting, &self.ctx, .none) catch |err| {
        log.err("watch: cook failed: {s}", .{@errorName(err)});
        self.callback.notify(.{ .metrics = .{}, .ok = false });
        return;
    };
    self.ctx.force = false;

    const ok = metrics.assets_errored == 0;
    if (ok) {
        log.info("watch: cooked {d} assets ({d} cooked, {d} cached)", .{
            metrics.assets_total, metrics.assets_cooked, metrics.assets_cached,
        });
    } else {
        log.warn("watch: cooked finished with {d} error(s); will retry on next change", .{metrics.assets_errored});
    }

    self.callback.notify(.{ .metrics = metrics, .ok = ok });
}

fn settle(self: *Watcher, first: Snapshot) !Snapshot {
    var latest = first;
    errdefer latest.deinit();

    const start = std.Io.Clock.Timestamp.now(self.io, .awake);
    while (true) {
        try self.io.sleep(self.options.debounce, .awake);

        var again = try Snapshot.capture(self.gpa, self.io, self.ctx.source);
        const quiet = Snapshot.eql(&latest, &again);
        latest.deinit();

        latest = again;
        if (quiet) {
            return latest;
        }

        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        if (start.durationTo(now).raw.nanoseconds >= self.options.debounce_Max.nanoseconds) {
            log.warn("watch: tree still changing after {f}; cooking anyway", .{self.options.debounce_Max});
            return latest;
        }
    }
}

const testing = std.testing;

const Observer = struct {
    calls: std.atomic.Value(usize) = .init(0),
    successful_calls: std.atomic.Value(usize) = .init(0),
    failed_calls: std.atomic.Value(usize) = .init(0),
    last_cooked: std.atomic.Value(u32) = .init(0),

    fn onCook(ctx: ?*anyopaque, result: CookResult) void {
        const self: *Observer = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (result.ok) {
            _ = self.successful_calls.fetchAdd(1, .monotonic);
        } else {
            _ = self.failed_calls.fetchAdd(1, .monotonic);
        }
        self.last_cooked.store(result.metrics.assets_cooked, .release);
    }

    fn callback(self: *Observer) Callback {
        return .{ .ctx = self, .on_cook = onCook };
    }
};

fn testContext(source: std.Io.Dir, output: std.Io.Dir) CookContext {
    return .{
        .io = testing.io,
        .source = source,
        .output = output,
        .output_path = ".",
        .force = false,
    };
}

fn waitForCalls(observer: *const Observer, expected: usize) !void {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (observer.calls.load(.acquire) >= expected) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TimedOut;
}

test "Watcher stop records a cooperative stop request" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();

    const source = try source_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer source.close(testing.io);
    const output = try output_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer output.close(testing.io);
    var watcher = Watcher.init(testing.allocator, testing.io, testContext(source, output), .{}, .{});
    defer watcher.deinit();

    try testing.expect(!watcher.should_stop.load(.acquire));
    watcher.stop();
    try testing.expect(watcher.should_stop.load(.acquire));
}

test "Watcher settle returns a stable snapshot" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();
    try source_tmp.dir.writeFile(testing.io, .{ .sub_path = "mesh.obj", .data = "v 0 0 0\n" });

    const source = try source_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer source.close(testing.io);
    const output = try output_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer output.close(testing.io);

    var watcher = Watcher.init(testing.allocator, testing.io, testContext(source, output), .{
        .debounce = .fromMilliseconds(1),
    }, .{});
    defer watcher.deinit();

    const first = try Snapshot.capture(testing.allocator, testing.io, source);
    var settled = try watcher.settle(first);
    defer settled.deinit();

    try testing.expectEqual(@as(usize, 1), settled.files.count());
    try testing.expect(settled.files.contains("mesh.obj"));
}

test "Watcher cook reports successful empty source trees" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();

    const source = try source_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer source.close(testing.io);
    const output = try output_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer output.close(testing.io);
    var observer = Observer{};
    var watcher = Watcher.init(testing.allocator, testing.io, testContext(source, output), .{}, observer.callback());
    defer watcher.deinit();

    watcher.cook();

    try testing.expectEqual(@as(usize, 1), observer.calls.load(.acquire));
    try testing.expectEqual(@as(usize, 1), observer.successful_calls.load(.acquire));
    try testing.expectEqual(@as(usize, 0), observer.failed_calls.load(.acquire));
    try testing.expectEqual(@as(u32, 0), observer.last_cooked.load(.acquire));
}

test "Watcher runs an initial cook and recooks a changed asset" {
    var source_tmp = testing.tmpDir(.{});
    defer source_tmp.cleanup();
    var output_tmp = testing.tmpDir(.{});
    defer output_tmp.cleanup();
    try source_tmp.dir.writeFile(testing.io, .{ .sub_path = "triangle.obj", .data =
        "v 0 0 0\n" ++
        "v 1 0 0\n" ++
        "v 0 1 0\n" ++
        "f 1 2 3\n",
    });

    const source = try source_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer source.close(testing.io);
    const output = try output_tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer output.close(testing.io);

    var observer = Observer{};
    var watcher = Watcher.init(testing.allocator, testing.io, testContext(source, output), .{
        .poll_interval = .fromMilliseconds(10),
        .debounce = .fromMilliseconds(5),
        .debounce_Max = .fromMilliseconds(100),
    }, observer.callback());
    defer watcher.deinit();

    var future = try std.Io.concurrent(testing.io, Watcher.run, .{&watcher});
    errdefer _ = future.cancel(testing.io) catch {};

    try waitForCalls(&observer, 1);
    try output_tmp.dir.access(testing.io, "triangle.zmesh", .{});

    // Give run() time to establish its baseline snapshot after the initial
    // callback, then make a real source change for the next watcher tick.
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try source_tmp.dir.writeFile(testing.io, .{ .sub_path = "triangle.obj", .data =
        "v 0 0 0\n" ++
        "v 2 0 0\n" ++
        "v 0 2 0\n" ++
        "f 1 2 3\n",
    });
    try waitForCalls(&observer, 2);

    watcher.stop();
    try future.cancel(testing.io);

    try testing.expectEqual(@as(usize, 2), observer.successful_calls.load(.acquire));
    try testing.expectEqual(@as(usize, 0), observer.failed_calls.load(.acquire));
    try testing.expect(observer.last_cooked.load(.acquire) >= 1);
}
