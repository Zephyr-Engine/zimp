const std = @import("std");

test {
    _ = @import("assets/asset.zig");
    _ = @import("assets/asset_scanner.zig");
    _ = @import("assets/source_file.zig");
    _ = @import("assets/raw/mesh.zig");
    _ = @import("assets/cooked/mesh.zig");
    _ = @import("commands/command.zig");
    _ = @import("gltf/glb_reader.zig");
    _ = @import("gltf/gltf_json_parser.zig");
    _ = @import("gltf/mesh.zig");
    _ = @import("inspectors/inspect.zig");
    _ = @import("inspectors/zmesh.zig");
    _ = @import("inspectors/utils.zig");
}

pub const CookStepOptions = struct {
    source_dir: std.Build.LazyPath,
    output_dir: std.Build.LazyPath,
};

pub fn addCookStep(b: *std.Build, dep: *std.Build.Dependency, options: CookStepOptions) *std.Build.Step.Run {
    const exe = dep.artifact("zimp");
    const run = b.addRunArtifact(exe);
    run.addArg("cook");
    run.addArg("--source");
    run.addDirectoryArg(options.source_dir);
    run.addArg("--output");
    run.addDirectoryArg(options.output_dir);
    return run;
}
