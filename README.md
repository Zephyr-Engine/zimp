# zimp (Zephyr Import - IN DEVELOPMENT)

A build-time asset compiler for Zig 0.16 that converts source assets into GPU-optimized binary formats and packs them into archive files for zero-parse runtime loading.

Designed for the [Zephyr Game Engine](https://github.com/Zephyr-Engine) but fully standalone — usable in any Zig project that needs an offline asset pipeline.

## Features

- **Build-time cooking** — converts source assets (GLTF, PNG, GLSL, WAV, TTF) into flat binary formats (`.za*`) optimized for `mmap` and direct GPU upload.
- **SoA mesh layout** — vertex streams stored separately (positions, normals, UVs) so the engine binds only what each render pass needs.
- **Vertex optimization** — deduplication, vertex cache reordering (Forsyth), and quantization (octahedral normals, f16 tangents, normalized u16 UVs).
- **Texture classification** — automatic format selection (BC7/BC5/BC4) based on filename convention, material slot, or sidecar override.
- **Block compression** — built-in BC4, BC5, and BC7 encoders written in Zig. No external texture tools required.
- **Shader preprocessing** — `#include` resolution, `#ifdef` variant expansion, and optional SPIR-V compilation with reflection extraction.
- **Incremental builds** — content-hashed `.zacache` with dependency graph tracking. Only re-cooks what changed.
- **Pack files** — combines all cooked assets into a single `.zpak` archive with a sorted TOC for O(log n) lookup and optional LZ4 compression.
- **Dual interface** — plugs into `build.zig` as a build step or runs as a standalone CLI for ad-hoc usage.
- **Zero runtime dependencies** — cooked formats are self-contained binary blobs. No third-party parsers at runtime.

## Pipeline Overview

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                          Source Assets                              │
  │   .glb  .gltf  .obj  .png  .jpg  .hdr  .glsl  .wav  .ogg  .ttf   │
  └──────────────────────────────┬──────────────────────────────────────┘
                                 │
                                 ▼
                          ┌────────────┐
                          │  Discover  │  scan dir, hash files,
                          │            │  build dependency graph
                          └──────┬─────┘
                                 │
                                 ▼
                          ┌────────────┐
                          │    Cook    │  convert to .za* binary formats
                          │            │  (parallel, incremental)
                          └──────┬─────┘
                                 │
            ┌──────────┬─────────┼─────────┬──────────┐
            ▼          ▼         ▼         ▼          ▼
         .zamesh   .zatex    .zashdr    .zasnd     .zafont
         .zaskel   .zamat               .zastream
         .zaanim
                                 │
                                 ▼
                          ┌────────────┐
                          │    Pack    │  combine into .zpak archive
                          │            │  with TOC + optional LZ4
                          └──────┬─────┘
                                 │
                                 ▼
                            game.zpak
```

## Requirements

- Zig 0.16+

## Installing

Add zimp as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Zephyr-Engine/zimport.git
```

Then in your `build.zig`:

```zig
const zimp_dep = b.dependency("zimp", .{
    .target = target,
    .optimize = optimize,
});
const zimp_mod = zimp_dep.module("zimp");

const import_step = zimp.addAssetStep(b, .{
    .source_dir = "assets/",
    .output_dir = "cooked/",
    .pack_output = "game.zpak",
    .incremental = true,
});

// Game exe depends on cooked assets
exe.step.dependOn(&import_step.step);
```

## Running the CLI

```sh
zig build cli
```

### Cook assets

```sh
# Cook an entire directory
zimp cook --source assets/ --output cooked/
```

### Pack into archive

```sh
zimp pack --input cooked/ --output game.zpak
```

### Inspect cooked assets

```sh
# Dump .zpak table of contents
zimp inspect game.zpak

# Dump a cooked asset header
zimp inspect cooked/player.zamesh
```

## Running tests

```sh
zig build test --summary all
```

## Cooked formats

### Meshes (`.zamesh`)

Source: `.glb`, `.gltf`, `.obj`

Flat binary blob with SoA vertex streams, directly uploadable to the GPU with zero parsing:

```zig
const zamesh = @import("zimp").formats.zamesh;

const mesh = try zamesh.read(allocator, file);
defer mesh.deinit();

// Bind only the streams you need
gl.bufferData(gl.ARRAY_BUFFER, mesh.positions, gl.STATIC_DRAW);
```

| Stream | Type | Notes |
|--------|------|-------|
| Positions | `[3]f32` | Always present |
| Normals | `[2]s16` | Octahedral encoding, reconstruct Z in shader |
| Tangents | `[4]f16` | Mikktspace |
| UV0 | `[2]u16` | Normalized to 0–65535 |
| UV1 | `[2]u16` | Optional second UV set |
| Joint indices | `[4]u16` | For skinned meshes |
| Joint weights | `[4]f16` | For skinned meshes |

Includes AABB bounding box, submesh table (per-material index ranges), and optional LOD chain.

### Skeletons (`.zaskel`) & Animations (`.zaanim`)

Source: embedded in `.glb`/`.gltf`

Skeletons are flat joint arrays ordered parent-before-child for single-pass FK. Animations store per-joint keyframe channels with f16 quaternion compression and delta-encoded translations. Clips include an event track for gameplay triggers (footstep sounds, VFX cues).

### Textures (`.zatex`)

Source: `.png`, `.jpg`, `.hdr`, `.exr`

Pre-mipmapped and block-compressed. Format is auto-selected by texture classification:

| Usage | Format | Classification |
|-------|--------|----------------|
| Color / Albedo | BC7 (sRGB) | `*_albedo.*`, `*_diffuse.*`, `*_color.*` |
| Normal maps | BC5 (linear) | `*_normal.*`, `*_nrm.*` |
| Roughness / Metallic / AO (packed) | BC7 (linear) | `*_orm.*`, `*_rm.*` |
| Single channel (roughness, height, AO) | BC4 (linear) | `*_roughness.*`, `*_height.*`, `*_ao.*` |
| HDR environment maps | Raw f16 | `*.hdr`, `*.exr` |

Classification priority: sidecar `.zameta` override > material slot name > filename convention > default (BC7 sRGB).

### Shaders (`.zashdr`)

Source: `.glsl`, `.vert`, `.frag`, `.comp`

Preprocessed GLSL with `#include` resolution and `#ifdef` variant expansion. On OpenGL, stores final GLSL source text for runtime compilation. On Vulkan, stores SPIR-V bytecode with extracted reflection data (descriptor sets, push constants, vertex inputs).

### Materials (`.zamat`)

Source: `.zamat` (TOML text)

Binary material definitions referencing cooked shaders and textures by path hash, with inline parameter blocks packed to match the shader's uniform layout.

```toml
[material]
shader = "shaders/pbr_standard"

[textures]
albedo = "textures/brick_albedo.png"
normal = "textures/brick_normal.png"
roughness_metallic = "textures/brick_rm.png"

[params]
uv_scale = [2.0, 2.0]
emissive_strength = 0.0
```

### Audio (`.zasnd`, `.zastream`)

Source: `.wav`, `.ogg`, `.flac`

Short clips (< 5s) are stored as uncompressed PCM for instant playback. Long clips are Ogg Vorbis compressed and chunked into ~1s pages for streaming. All audio is loudness-normalized to EBU R128.

### Fonts (`.zafont`)

Source: `.ttf`, `.otf`

MSDF atlas with BC4-compressed distance field texture, glyph metrics, and kerning table. Renders crisply at any size.

## Pack file format (`.zpak`)

All cooked assets combine into a single `.zpak` archive:

```
┌──────────────────────────────────────────┐
│ Header: magic, version, TOC offset       │
├──────────────────────────────────────────┤
│ Asset data (sequential, page-aligned     │
│ for streaming assets)                    │
├──────────────────────────────────────────┤
│ Table of Contents (sorted by path hash)  │
├──────────────────────────────────────────┤
│ Footer checksum                          │
└──────────────────────────────────────────┘
```

```zig
const TocEntry = struct {
    path_hash: u64,       // FNV-1a of virtual asset path
    asset_type: u16,      // mesh, texture, shader, ...
    flags: u16,           // compressed, streaming
    offset: u64,          // byte offset into data block
    size_compressed: u32, // on-disk size
    size_raw: u32,        // decompressed size
    checksum: u32,        // CRC32
};
```

The engine loads the TOC at startup and does O(log n) binary search to find any asset. Individual assets are optionally LZ4-compressed (textures are skipped since BC data doesn't compress further). Multiple `.zpak` files can be layered with priority ordering for mod/DLC support.

## Incremental builds

zimp maintains a `.zacache` file that tracks content hashes and dependency relationships. On subsequent runs, only assets whose source files changed (or whose dependencies changed) are re-cooked. A material that references `brick_normal.png` will automatically re-cook when that texture is modified.

```sh
# First run: cooks everything
zimp cook --source assets/ --output cooked/
# Cooked 47 assets in 3.2s

# Second run: nothing changed
zimp cook --source assets/ --output cooked/
# 0 assets to cook (47 cached)

# After editing brick_normal.png
zimp cook --source assets/ --output cooked/
# Cooked 2 assets in 0.4s (brick_normal.zatex + brick.zamat)
```
