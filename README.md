# zimp (Zephyr Import - IN DEVELOPMENT)

A build-time asset compiler for Zig 0.16 that converts source assets into GPU-optimized binary formats, maintains durable asset identity, and generates the asset manifest the engine resolves assets through at runtime.

Designed for the [Zephyr Game Engine](https://github.com/Zephyr-Engine) but fully standalone — usable in any Zig project that needs an offline asset pipeline.

## Features

- **Build-time cooking** — converts source assets (glTF/GLB, OBJ, PNG/JPG/HDR, GLSL, TOML materials) into flat binary formats optimized for direct GPU upload.
- **Durable asset identity** — every authored asset gets a committed `.zmeta` sidecar carrying its `AssetId` (UUID). IDs survive recooks, cache deletion, and machine changes; renames preserve identity when the sidecar moves with the file.
- **Asset manifest** — project cooks emit `assets.zmanifest`, a deterministic database mapping `AssetId` → source path, cooked path, kind, and content hash. The runtime resolves assets through it instead of hard-coded paths.
- **Project mode** — `zimp cook --project <root>` reads `.zephyr/zephyr.proj` and derives all directories from the project manifest; no hand-wired source/output paths.
- **SoA mesh layout** — vertex streams stored separately (positions, normals, UVs) so the engine binds only what each render pass needs.
- **Vertex quantization** — octahedral normals (`[2]i16`), `f16` tangents, normalized `u16` UVs, `u16` indices where they fit.
- **Texture classification** — automatic format selection (BC7/BC5/BC4) from filename convention (`*_albedo`, `*_normal`, ...) and material slot.
- **Block compression** — built-in BC4, BC5, BC6H, and BC7 encoders written in Zig. No external texture tools required.
- **Shader preprocessing** — `#include` resolution and variant expansion; cooked shaders store final GLSL source per stage.
- **glTF material extraction** — materials and embedded images inside `.glb`/`.gltf` are auto-generated as sources under `generated/` (with deterministic derived ids) and cooked in the same run.
- **Incremental builds** — content-hashed `.zcache` with dependency graph tracking. Only re-cooks what changed.
- **Dual interface** — plugs into `build.zig` as a build step (`addProjectCookStep`) or runs as a standalone CLI.
- **Zero runtime dependencies** — cooked formats are self-contained binary blobs. No third-party parsers at runtime.

## Pipeline Overview

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                          Source Assets                              │
  │      .glb  .gltf  .obj  .png  .jpg  .hdr  .vert  .frag  .zamat      │
  │      (+ committed .zmeta identity sidecars next to each source)     │
  └──────────────────────────────┬──────────────────────────────────────┘
                                 │
                                 ▼
                          ┌────────────┐
                          │  Discover  │  scan dir, hash files, build dependency graph
                          └──────┬─────┘
                                 │
                                 ▼
                          ┌────────────┐
                          │    Cook    │  convert to binary formats (parallel, incremental)
                          └──────┬─────┘
                                 │
                 ┌───────────┬───┴─────┬───────────┐
                 ▼           ▼         ▼           ▼
              .zmesh      .ztex     .zshdr      .zamat
                                 │
                                 ▼  (project mode)
                          ┌────────────┐
                          │  Identity  │  resolve AssetIds (sidecar / derived / new),
                          └──────┬─────┘  write assets.zmanifest, flush new sidecars
                                 │
                                 ▼
                        assets.zmanifest
```

## Requirements

- Zig 0.16+

## Installing

Add zimp as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Zephyr-Engine/zimp.git
```

Then in your `build.zig`, cook the project as a build step:

```zig
const zimp = @import("zimp");

const zimp_dep = b.dependency("zimp", .{
    .target = target,
    .optimize = .ReleaseFast,
});

// Project root = the directory containing .zephyr/zephyr.proj.
const cook = zimp.addProjectCookStep(b, zimp_dep, b.path("."));
const cook_step = b.step("cook", "Cook assets with zimp");
cook_step.dependOn(&cook.step);

// Game exe depends on cooked assets
run_cmd.step.dependOn(&cook.step);
```

## Running the CLI

```sh
zig build run -- <command> [flags]
```

### Cook a project (recommended)

Reads `.zephyr/zephyr.proj`, cooks `assets_dir` into `cooked_assets_dir`, resolves durable ids, and writes `assets.zmanifest`:

```sh
zimp cook --project path/to/project
```

### Cook a bare directory

Directory mode cooks without a project: no identity, no manifest. Useful for ad-hoc conversion; the Zephyr runtime requires a manifest and will not load from a dir-mode cook.

```sh
zimp cook --source assets/ --output cooked/

# Force a full recook, ignoring the incremental cache
zimp cook --project . --force

# Emit machine-readable metrics for CI parsing
zimp cook --source assets/ --output cooked/ --metrics-json
```

### Inspect cooked assets

```sh
zimp inspect cooked/monkey.zmesh
zimp inspect cooked/basic.vert.zshdr
zimp inspect cooked/monkey.zamat
zimp inspect cooked/.zcache          # directory mode
zimp inspect .zephyr/.zcache         # project mode
```

## Running tests

```sh
zig build test --summary all
```

## Durable asset identity

zimp is the source of truth for asset identity (see [`docs/identity.md`](docs/identity.md) for the full rules):

- **`.zmeta` sidecars** (`meshes/monkey.glb.zmeta`) carry each authored asset's `AssetId`. They are authored identity, committed to version control; deleting one assigns a NEW id on the next cook and breaks every reference to the asset.
- **`assets.zmanifest`** is generated output (never committed): a deterministic, validated JSON database of every cooked asset. Identical inputs produce byte-identical manifests.
- Ids are resolved by three frozen rules, in order: `generated/**` paths get deterministic derived ids (pure function of the path, no sidecar); an existing sidecar wins; otherwise a fresh UUIDv4 is minted and a sidecar written.
- Duplicate ids (e.g. a file copied together with its sidecar) are a hard cook error naming both paths. Corrupt sidecars are hard errors — zimp never silently re-identifies an asset. Sidecars are flushed only after the manifest write succeeds.

The shared ID types (`Uuid`, `AssetId`, `SceneId`, `SceneEntityId`, `ProjectId`, `ComponentTypeId`, `SchemaId`) live in `zimp.id` as distinct wrapper types, and the project manifest model (`zimp.ProjectManifest`, `zimp.ProjectRoot`) lives in `zimp.project`, so the cooker, runtime, and editor all share one definition.

## CI performance regression checks

CI runs a `cook` benchmark and extracts the `CI_METRICS_JSON` payload into an artifact (`cook-metrics-json`).
On pull requests, CI fetches the last 10 successful `main` artifacts, computes a median baseline per timing metric, and fails if current timings exceed:

- `total`: baseline + 15% (+10ms absolute tolerance)
- `cook`: baseline + 15% (+10ms absolute tolerance)
- `scan`, `dependency_graph`, `cache_write`: baseline + 20% (+10ms absolute tolerance)

This is a standard low-noise guard pattern: rolling-window baseline + median + percentage threshold.
You can tune the window and thresholds in `.github/workflows/test.yml` via `scripts/ci/check_perf_regression.py` flags.

To accept a new slower/faster baseline on a specific PR without disabling checks globally, add the PR label:

- `perf-baseline-accept`

When that label is present, CI still computes and reports regressions but does not fail the PR on perf deltas.

## Cooked formats

### Meshes (`.zmesh`)

Source: `.glb`, `.gltf`, `.obj`

Flat binary blob with SoA vertex streams, directly uploadable to the GPU with minimal parsing:

```zig
const zmesh = @import("zimp").formats.zmesh;

var read_buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &read_buffer);
var mesh = try zmesh.read(allocator, &file_reader.interface);
defer mesh.deinit(allocator);
```

| Stream | Type | Notes |
|--------|------|-------|
| Positions | `[3]f32` | Always present |
| Normals | `[2]i16` | Octahedral encoding, reconstruct Z in shader |
| Tangents | `[4]f16` | Optional |
| UV0 | `[2]u16` | Normalized to 0–65535 |
| UV1 | `[2]u16` | Optional second UV set |
| Joint indices | `[4]u16` | For skinned meshes |
| Joint weights | `[4]f16` | For skinned meshes |

Includes an AABB bounding box; indices are `u16` when they fit, `u32` otherwise.

Each source mesh file currently must contain exactly one glTF mesh. Files containing multiple glTF meshes fail with `MultipleMeshesUnsupported` instead of producing an ambiguous concatenated output.

### Textures (`.ztex`)

Source: `.png`, `.jpg`, `.jpeg`, `.hdr`

Pre-mipmapped and block-compressed. Format is auto-selected by texture classification:

| Usage | Format | Classification |
|-------|--------|----------------|
| Color / Albedo | BC7 (sRGB) | `*_albedo.*`, `*_diffuse.*`, `*_basecolor.*` |
| Normal maps | BC5 (linear) | `*_normal.*`, `*_nrm.*` |
| Roughness / Metallic / AO (packed) | BC7 (linear) | `*_orm.*`, `*_rm.*` |
| Single channel (roughness, height, AO) | BC4 (linear) | `*_roughness.*`, `*_height.*`, `*_ao.*` |

Classification priority: material slot name > filename convention > default (BC7 sRGB).

### Shaders (`.zshdr`)

Source: `.vert`, `.frag`, `.comp` (with `.glsl` includes)

Preprocessed GLSL per stage with `#include` resolution and variant expansion; stores final GLSL source text for runtime compilation. One cooked file per stage (`basic.vert.zshdr`, `basic.frag.zshdr`); the runtime links stage pairs into programs.

### Materials (`.zamat`)

Source: `.zamat` (TOML text)

Binary material definitions referencing cooked shaders and textures by path hash, with inline parameter blocks packed for shader uniform upload. The material writer only hashes referenced paths and does not need cooked shader or texture outputs, but the dependency graph still records those logical edges so cache invalidation cascades correctly.

```toml
[material]
shader = "shaders/pbr_standard"

[render_state]
alpha_mode = "solid"
alpha_cutoff = 0.5
double_sided = false
cull_mode = "back"
depth_test = true
depth_write = true
blend_mode = "disabled"

[texture.albedo]
path = "textures/brick_albedo.png"
resource = "u_albedo"
set = 0
binding = 0

[texture.normal]
path = "textures/brick_normal.png"
resource = "u_normal_map"
set = 0
binding = 1

[texture.roughness_metallic]
path = "textures/brick_rm.png"
resource = "u_roughness_metallic_map"
set = 0
binding = 6

[param.u_uv_scale]
value = [2.0, 2.0]
set = 1
binding = 0

[param.u_emissive_strength]
value = 0.0
set = 1
binding = 1
```

`[material]` holds metadata. `shader` is a base path that resolves to `<shader>.vert` and `<shader>.frag`; `[render_state]` stores draw-state such as alpha mode, culling, depth, and blending. Each `[texture.<slot>]` maps one semantic texture slot to a source texture path, an exact shader sampler `resource`, and binding metadata; standard slots are `albedo`, `normal`, `roughness`, `metallic`, `ao`, `emissive`, `roughness_metallic`, and `orm`, but custom slots are valid when `resource` names a reflected sampler. Each `[param.<uniform>]` maps one exact shader uniform name to a scalar, boolean, vec2, vec3, or vec4 literal plus binding metadata.

When `.glb` or `.gltf` files contain materials, zimp auto-generates material source files under `generated/materials/` and embedded image files under `generated/textures/`, then rescans so they cook in the same run. Generated sources get deterministic derived `AssetId`s (a pure function of their path — no sidecars) so regenerating them never changes identity. Hand-written files in `materials/` with the same generated filename take priority and are never overwritten. GLTF PBR fields map to standard slots and uniforms: base color texture to `albedo`, metallic-roughness texture to `roughness_metallic`, normal to `normal`, occlusion to `ao`, emissive texture to `emissive`, and factors to `u_base_color`, `u_metallic`, `u_roughness`, and `u_emissive`.

## Incremental builds

zimp maintains a `.zcache` file that tracks content hashes and dependency relationships. Project mode stores it at `<project>/.zephyr/.zcache`; directory mode stores it inside the selected output directory. This keeps independent projects and output roots from sharing mutable cache state. On subsequent runs, only assets whose source files changed (or whose dependencies changed) are re-cooked. A material that references `brick_normal.png` will automatically re-cook when that texture is modified.

```sh
# First run: cooks everything
zimp cook --project .
# Cooked 47 assets in 3.2s

# Second run: nothing changed
zimp cook --project .
# 0 assets to cook (47 cached)

# After editing brick_normal.png
zimp cook --project .
# Cooked 2 assets in 0.4s (brick_normal.ztex + brick.zamat)
```

Asset identity does not depend on the cache: deleting `.zcache` (or the whole cooked directory and manifest) and recooking reproduces identical `AssetId`s from the committed sidecars.

Cooked paths preserve the source directory structure and replace the source extension. For example, `meshes/characters/hero.glb` becomes `meshes/characters/hero.zmesh`. Shader stage extensions are retained (`shaders/basic.vert` becomes `shaders/basic.vert.zshdr`). This prevents assets in different directories from colliding; two source files in the same directory that would map to one output are rejected during planning.

## Planned

- `zimp pack` — combine cooked assets into a single archive with a sorted TOC for O(log n) lookup (the CLI command exists as a stub).
- Audio (`.wav`, `.ogg`) and font (`.ttf`) cooking.
- Skeleton/animation extraction from glTF.
- SPIR-V shader compilation with reflection extraction for a future Vulkan backend.
- Per-asset importer settings in `.zmeta` sidecars.
