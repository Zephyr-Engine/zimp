const std = @import("std");

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

pub const ZMesh = @import("formats/zmesh.zig").ZMesh;
pub const mesh = @import("assets/cooked/mesh.zig");

test {
    _ = @import("assets/asset.zig");
    _ = @import("assets/asset_scanner.zig");
    _ = @import("assets/source_file.zig");
    _ = @import("assets/raw/mesh.zig");
    _ = @import("assets/cooked/mesh.zig");
    _ = @import("commands/command.zig");
    _ = @import("parsers/gltf/glb_parser.zig");
    _ = @import("parsers/gltf/gltf_json_parser.zig");
    _ = @import("parsers/gltf/mesh.zig");
    _ = @import("cookers/cooker.zig");
    _ = @import("cookers/glb.zig");
    _ = @import("cookers/obj.zig");
    _ = @import("parsers/obj/obj_parser.zig");
    _ = @import("inspectors/inspect.zig");
    _ = @import("inspectors/zmesh.zig");
    _ = @import("inspectors/zcache.zig");
    _ = @import("inspectors/utils.zig");
    _ = @import("cache/cache.zig");
    _ = @import("cache/entry.zig");
}
