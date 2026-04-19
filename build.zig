const std = @import("std");
const zimp = @import("src/root.zig");

pub const addCookStep = zimp.addCookStep;
pub const CookStepOptions = zimp.CookStepOptions;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zimp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addIncludePath(b.path("external/image"));
    mod.addCSourceFile(.{
        .file = b.path("external/image/stb_image.c"),
        .flags = &.{"-O3"},
    });
    mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zimp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimp", .module = mod },
            },
        }),
    });
    exe.root_module.addIncludePath(b.path("external/image"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
