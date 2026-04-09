const std = @import("std");
const zimp = @import("zimp");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimp_dep = b.dependency("zimp", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const cook = zimp.addCookStep(b, zimp_dep, .{
        .source_dir = b.path("assets"),
        .output_dir = b.path("output"),
    });
    const cook_step = b.step("cook", "Cook assets with zimp");
    cook_step.dependOn(&cook.step);

    const exe = b.addExecutable(.{
        .name = "examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(&cook.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
