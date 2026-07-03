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

/// Binary cooked-asset formats and their reader/writer APIs.
///
/// For example, use `zimp.formats.zmesh.ZMesh.read` to load a mesh, or
/// `zimp.formats.ztex.TexelFormat` when creating texture resources.
pub const formats = struct {
    pub const zmesh = @import("formats/zmesh.zig");
    pub const ztex = @import("formats/ztex.zig");
    pub const zshdr = @import("formats/zshdr.zig");
    pub const zamat = @import("formats/zamat.zig");
};

/// Asset data types used by the cooked formats.
///
/// `raw` and `cooked` are useful to applications that produce assets
/// themselves; runtime consumers will normally only need `formats` and
/// `runtime`.
pub const assets = struct {
    pub const raw = struct {
        pub const mesh = @import("assets/raw/mesh.zig");
        pub const texture = @import("assets/raw/texture.zig");
        pub const shader = @import("assets/raw/shader.zig");
        pub const material = @import("assets/raw/material.zig");
    };

    pub const cooked = struct {
        pub const mesh = @import("assets/cooked/mesh.zig");
        pub const texture = @import("assets/cooked/texture.zig");
        pub const shader = @import("assets/cooked/shader.zig");
        pub const material = @import("assets/cooked/material.zig");
    };
};

/// Load cooked assets from a directory or a reader, with virtual-path
/// validation suitable for application asset roots.
pub const runtime = @import("runtime.zig");

/// Path normalization, cooked output path naming, and virtual asset path checks.
pub const path = @import("path.zig");

// Convenient top-level aliases retained for existing users.
pub const ZMesh = formats.zmesh.ZMesh;
pub const ZMeshHeader = formats.zmesh.ZMeshHeader;
pub const FormatFlags = assets.cooked.mesh.FormatFlags;
pub const CookedVertex = assets.cooked.mesh.CookedVertex;
pub const AABB = assets.cooked.mesh.AABB;
pub const IndexFormat = assets.cooked.mesh.IndexFormat;
pub const IndexBuffer = assets.cooked.mesh.IndexBuffer;
pub const CookedMesh = assets.cooked.mesh.CookedMesh;
pub const Zatex = formats.ztex.Zatex;
pub const ZatexHeader = formats.ztex.ZatexHeader;
pub const TextureType = formats.ztex.TextureType;
pub const TexelFormat = assets.cooked.texture.TexelFormat;
pub const ColorSpace = assets.raw.texture.ColorSpace;
pub const TextureClass = assets.raw.texture.TextureClass;
pub const CookedMip = assets.cooked.texture.CookedMip;
pub const CookedTexture = assets.cooked.texture.CookedTexture;
pub const ZShader = formats.zshdr.ZShader;
pub const ShaderStage = formats.zshdr.ShaderStage;
pub const VariantKey = formats.zshdr.VariantKey;
pub const CookedShader = assets.cooked.shader.CookedShader;
pub const Zamat = formats.zamat.Zamat;
pub const ZamatHeader = formats.zamat.ZamatHeader;
pub const LoadedMaterial = formats.zamat.Material;
pub const loadMaterial = formats.zamat.loadMaterial;
pub const AlphaMode = assets.cooked.material.AlphaMode;
pub const CullMode = assets.cooked.material.CullMode;
pub const BlendMode = assets.cooked.material.BlendMode;
pub const FilterMode = assets.cooked.material.FilterMode;
pub const MipFilterMode = assets.cooked.material.MipFilterMode;
pub const WrapMode = assets.cooked.material.WrapMode;
pub const SamplerDesc = assets.cooked.material.SamplerDesc;
pub const RenderState = assets.cooked.material.RenderState;
pub const TextureSlotIndex = assets.cooked.material.TextureSlotIndex;
pub const slotNameToIndex = assets.cooked.material.slotNameToIndex;
pub const TextureSlotEntry = assets.cooked.material.TextureSlotEntry;
pub const ParamType = assets.cooked.material.ParamType;
pub const ParamEntry = assets.cooked.material.ParamEntry;
pub const ParamBuildResult = assets.cooked.material.ParamBuildResult;
pub const CookedMaterial = assets.cooked.material.CookedMaterial;
pub const MaterialSource = assets.raw.material.MaterialSource;
pub const TextureSlot = assets.raw.material.TextureSlot;
pub const ParamValue = assets.raw.material.ParamValue;
pub const parseMaterialSource = assets.raw.material.parseMaterialSource;
pub const parseAlphaMode = assets.raw.material.parseAlphaMode;
pub const mesh = assets.cooked.mesh;
pub const material = assets.cooked.material;

const asset = @import("assets/asset.zig");
pub const AssetType = asset.AssetType;
pub const Extension = asset.Extension;

test "public API exposes format and asset construction types" {
    _ = formats.zmesh.ZMesh;
    _ = formats.ztex.Zatex;
    _ = formats.zshdr.ZShader;
    _ = formats.zamat.Zamat;

    _ = assets.raw.mesh.RawMesh;
    _ = assets.raw.texture.RawTexture;
    _ = assets.raw.shader.RawShader;
    _ = assets.raw.material.MaterialSource;

    _ = CookedMesh;
    _ = CookedTexture;
    _ = CookedShader;
    _ = CookedMaterial;
    _ = AlphaMode;
    _ = CullMode;
    _ = BlendMode;
    _ = FilterMode;
    _ = MipFilterMode;
    _ = WrapMode;
    _ = SamplerDesc;
    _ = RenderState;
    _ = TextureSlotIndex;
    _ = slotNameToIndex;
    _ = TextureSlotEntry;
    _ = ParamType;
    _ = ParamEntry;
    _ = ParamBuildResult;
    _ = MaterialSource;
    _ = TextureSlot;
    _ = ParamValue;
    _ = parseMaterialSource;
    _ = parseAlphaMode;
    _ = LoadedMaterial;
    _ = loadMaterial;
    _ = path.normalizeVirtual;
    _ = path.resolveShaderInclude;
    _ = path.cookedOutput;
}

test {
    _ = @import("assets/asset.zig");
    _ = @import("assets/asset_scanner.zig");
    _ = @import("assets/dependency_graph.zig");
    _ = @import("assets/source_file.zig");
    _ = @import("assets/raw/mesh.zig");
    _ = @import("assets/raw/texture.zig");
    _ = @import("assets/raw/shader.zig");
    _ = @import("assets/raw/material.zig");
    _ = @import("assets/cooked/mesh.zig");
    _ = @import("assets/cooked/texture.zig");
    _ = @import("assets/cooked/shader.zig");
    _ = @import("assets/cooked/material.zig");
    _ = @import("formats/zshdr.zig");
    _ = @import("formats/zamat.zig");
    _ = @import("assets/cooked/compression/compression.zig");
    _ = @import("assets/cooked/compression/bc4.zig");
    _ = @import("assets/cooked/compression/bc5.zig");
    _ = @import("assets/cooked/compression/bc7.zig");
    _ = @import("assets/cooked/compression/bc6h.zig");
    _ = @import("commands/command.zig");
    _ = @import("commands/cook_metrics.zig");
    _ = @import("parsers/gltf/glb_parser.zig");
    _ = @import("parsers/gltf/gltf_json_parser.zig");
    _ = @import("parsers/gltf/document.zig");
    _ = @import("parsers/gltf/mesh.zig");
    _ = @import("parsers/gltf/material_generator.zig");
    _ = @import("cookers/cooker.zig");
    _ = @import("cookers/glb.zig");
    _ = @import("cookers/gltf.zig");
    _ = @import("cookers/obj.zig");
    _ = @import("cookers/shader.zig");
    _ = @import("cookers/material.zig");
    _ = @import("extractors/extractor.zig");
    _ = @import("extractors/mesh.zig");
    _ = @import("extractors/shader.zig");
    _ = @import("extractors/material.zig");
    _ = @import("parsers/obj/obj_parser.zig");
    _ = @import("inspectors/inspect.zig");
    _ = @import("inspectors/zmesh.zig");
    _ = @import("inspectors/zshdr.zig");
    _ = @import("inspectors/zamat.zig");
    _ = @import("inspectors/zcache.zig");
    _ = @import("inspectors/utils.zig");
    _ = @import("cache/cache.zig");
    _ = @import("cache/cache_dep_graph.zig");
    _ = @import("cache/entry.zig");
    _ = @import("shared/file_read.zig");
    _ = @import("runtime.zig");
    _ = @import("path.zig");
}
