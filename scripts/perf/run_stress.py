#!/usr/bin/env python3
"""Generate a deterministic large asset suite and measure zimp cooking.

The fixture is generated locally rather than checked in as binary blobs: it is
large enough to exercise texture compression, mesh conversion, dependency
planning, cache hits, and invalidation without bloating the repository.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path
from typing import Any


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MARKER_NAME = ".zimp-perf-fixture"
METRICS_PREFIX = "COOK_METRICS_JSON "
SOURCE_EXTENSIONS = {".obj", ".png", ".vert", ".frag", ".glsl", ".zamat"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run zimp's deterministic, dependency-heavy cooking stress suite."
    )
    parser.add_argument(
        "--zimp",
        default="zig-out/bin/zimp",
        help="Path to the zimp executable built by Zig (default: zig-out/bin/zimp).",
    )
    parser.add_argument(
        "--work-dir",
        default=".perf/zimp-stress",
        help="Directory used for generated sources, outputs, and results.",
    )
    parser.add_argument(
        "--texture-size",
        type=int,
        default=2048,
        help="Width and height of each generated RGBA texture (default: 2048).",
    )
    parser.add_argument(
        "--mesh-grid",
        type=int,
        default=384,
        help="Number of quads on each axis of the generated OBJ mesh (default: 384).",
    )
    parser.add_argument(
        "--materials",
        type=int,
        default=32,
        help="Number of materials sharing the shader and texture dependency fan-in.",
    )
    parser.add_argument(
        "--include-depth",
        type=int,
        default=24,
        help="Depth of the generated shader include chain.",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Use a smaller fixture for a fast smoke run (512px textures, 128x128 mesh).",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    for name in ("texture_size", "mesh_grid", "materials", "include_depth"):
        if getattr(args, name) < 1:
            raise SystemExit(f"--{name.replace('_', '-')} must be at least 1")
    if args.texture_size < 4:
        raise SystemExit("--texture-size must be at least 4 for block compression")


def ensure_owned_work_dir(repo_root: Path, work_dir: Path) -> None:
    resolved_root = repo_root.resolve()
    resolved_work = work_dir.resolve()
    if resolved_work == resolved_root or resolved_root not in resolved_work.parents:
        raise SystemExit("--work-dir must be a child of the repository root")

    if work_dir.exists():
        marker = work_dir / MARKER_NAME
        if not marker.exists():
            raise SystemExit(
                f"Refusing to replace '{work_dir}': it is not a stress-suite directory. "
                f"Delete it manually or choose another --work-dir."
            )
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)
    (work_dir / MARKER_NAME).write_text("This directory is owned by scripts/perf/run_stress.py\n")


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def pixel_row(width: int, y: int, salt: int, texture_kind: str) -> bytes:
    row = bytearray(1 + width * 4)
    # PNG filter method 0. The mix deliberately avoids an overly compressible
    # source image, so file hashing and decoding are substantial work too.
    for x in range(width):
        i = 1 + x * 4
        mix = (x * 0x45D9F3B + y * 0x27D4EB2D + salt * 0x165667B1) & 0xFFFFFFFF
        mix ^= mix >> 16
        mix = (mix * 0x7FEB352D) & 0xFFFFFFFF
        mix ^= mix >> 15
        if texture_kind == "normal":
            row[i : i + 4] = bytes(((mix & 7) + 124, ((mix >> 3) & 7) + 124, 255, 255))
        elif texture_kind == "mask":
            value = mix & 0xFF
            row[i : i + 4] = bytes((value, value, value, 255))
        else:
            row[i : i + 4] = bytes((mix & 0xFF, (mix >> 8) & 0xFF, (mix >> 16) & 0xFF, 255))
    return bytes(row)


def write_png(path: Path, size: int, salt: int, texture_kind: str) -> None:
    compressor = zlib.compressobj(level=1)
    with path.open("wb") as output:
        output.write(PNG_SIGNATURE)
        output.write(png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)))
        output.write(png_chunk(b"IDAT", compressor.compress(pixel_row(size, 0, salt, texture_kind))))
        for y in range(1, size):
            compressed = compressor.compress(pixel_row(size, y, salt, texture_kind))
            if compressed:
                output.write(png_chunk(b"IDAT", compressed))
        final = compressor.flush()
        if final:
            output.write(png_chunk(b"IDAT", final))
        output.write(png_chunk(b"IEND", b""))


def write_mesh(path: Path, grid: int) -> None:
    """Write a large indexed grid with >65k vertices to exercise u32 indices."""
    side = grid + 1
    with path.open("w", encoding="utf-8", newline="\n") as output:
        output.write("# Generated zimp performance stress mesh\n")
        for y in range(side):
            fy = y / grid
            for x in range(side):
                fx = x / grid
                z = ((x * 17 + y * 31) % 23) / 2300.0
                output.write(f"v {fx:.6f} {fy:.6f} {z:.6f}\n")
        for _ in range(side * side):
            output.write("vn 0.0 0.0 1.0\n")
        for y in range(side):
            fy = y / grid
            for x in range(side):
                output.write(f"vt {x / grid:.6f} {fy:.6f}\n")
        for y in range(grid):
            for x in range(grid):
                a = y * side + x + 1
                b = a + 1
                c = a + side + 1
                d = c + 1
                output.write(f"f {a}/{a}/{a} {b}/{b}/{b} {c}/{c}/{c}\n")
                output.write(f"f {a}/{a}/{a} {c}/{c}/{c} {d}/{d}/{d}\n")


def write_shaders(shader_dir: Path, include_depth: int) -> None:
    includes = shader_dir / "includes"
    includes.mkdir(parents=True)
    (includes / "layer_00.glsl").write_text(
        "float perfLayer00(float value) { return value + 0.0001; }\n", encoding="utf-8"
    )
    for layer in range(1, include_depth):
        (includes / f"layer_{layer:02d}.glsl").write_text(
            f'#include "layer_{layer - 1:02d}.glsl"\n'
            f"float perfLayer{layer:02d}(float value) {{ return perfLayer{layer - 1:02d}(value) * 1.00001; }}\n",
            encoding="utf-8",
        )

    # Four branches create a wide dependency fan-out while all paths share the
    # same include chain. Any leaf change therefore tests reverse invalidation.
    branch_layers = [include_depth - 1, include_depth * 3 // 4, include_depth // 2, include_depth // 4]
    for branch, layer in enumerate(branch_layers):
        (includes / f"branch_{branch}.glsl").write_text(
            f'#include "layer_{layer:02d}.glsl"\n'
            f"float perfBranch{branch}(float value) {{ return perfLayer{layer:02d}(value) + {branch}.0; }}\n",
            encoding="utf-8",
        )

    last = include_depth - 1
    (shader_dir / "stress.vert").write_text(
        "#version 330 core\n"
        '#include "includes/branch_0.glsl"\n'
        "layout(location = 0) in vec3 a_position;\n"
        "uniform mat4 u_model;\n"
        "void main() { gl_Position = u_model * vec4(a_position, perfBranch0(1.0)); }\n",
        encoding="utf-8",
    )
    (shader_dir / "stress.frag").write_text(
        "#version 330 core\n"
        "// VARIANTS: HAS_ALBEDO_MAP, HAS_NORMAL_MAP, HAS_ORM_MAP, HAS_ROUGHNESS_MAP, HAS_EMISSIVE_MAP\n"
        + "".join(f'#include "includes/branch_{branch}.glsl"\n' for branch in range(4))
        + "uniform sampler2D u_albedo;\n"
        "uniform sampler2D u_normal;\n"
        "uniform sampler2D u_orm;\n"
        "uniform sampler2D u_roughness;\n"
        "uniform sampler2D u_emissive;\n"
        "uniform float u_roughness_scale;\n"
        "uniform vec3 u_tint;\n"
        "in vec2 v_uv;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  float v = perfBranch0(perfBranch1(perfBranch2(perfBranch3(v_uv.x))));\n"
        "  vec3 color = texture(u_albedo, v_uv).rgb * u_tint;\n"
        "  frag_color = vec4(color * (v + u_roughness_scale), 1.0);\n"
        "}\n",
        encoding="utf-8",
    )


def material_source(index: int) -> str:
    return f'''# Generated material {index}
[material]
shader = "shaders/stress"

[texture.albedo]
path = "textures/world_albedo.png"
resource = "u_albedo"
binding = 0

[texture.normal]
path = "textures/world_normal.png"
resource = "u_normal"
binding = 1

[texture.orm]
path = "textures/world_orm.png"
resource = "u_orm"
binding = 2

[texture.roughness]
path = "textures/world_roughness.png"
resource = "u_roughness"
binding = 3

[texture.emissive]
path = "textures/world_emissive.png"
resource = "u_emissive"
binding = 4

[param.u_roughness_scale]
value = {0.2 + (index % 10) / 20:.2f}
binding = 0

[param.u_tint]
value = [1.0, {0.5 + (index % 8) / 16:.3f}, 0.75]
binding = 1
'''


def generate_fixture(source: Path, texture_size: int, mesh_grid: int, materials: int, include_depth: int) -> dict[str, int]:
    textures = source / "textures"
    shaders = source / "shaders"
    material_dir = source / "materials"
    mesh_dir = source / "meshes"
    for directory in (textures, shaders, material_dir, mesh_dir):
        directory.mkdir(parents=True)

    texture_specs = (
        ("world_albedo.png", "color"),
        ("world_normal.png", "normal"),
        ("world_orm.png", "color"),
        ("world_roughness.png", "mask"),
        ("world_emissive.png", "color"),
    )
    for salt, (name, kind) in enumerate(texture_specs, start=1):
        write_png(textures / name, texture_size, salt, kind)

    write_mesh(mesh_dir / "terrain_stress.obj", mesh_grid)
    write_shaders(shaders, include_depth)
    for index in range(materials):
        (material_dir / f"stress_{index:03d}.zamat").write_text(material_source(index), encoding="utf-8")

    return {
        "textures": len(texture_specs),
        "meshes": 1,
        "shader_stages": 2,
        "shader_includes": include_depth + 4,
        "materials": materials,
        # Every material depends directly on two stages and five textures.
        "direct_material_edges": materials * 7,
    }


def bytes_on_disk(directory: Path, extensions: set[str] | None = None) -> int:
    total = 0
    for path in directory.rglob("*"):
        if path.is_file() and (extensions is None or path.suffix in extensions):
            total += path.stat().st_size
    return total


def asset_count(directory: Path) -> int:
    return sum(1 for path in directory.rglob("*") if path.is_file() and path.suffix in SOURCE_EXTENSIONS)


def run_cook(zimp: Path, source: Path, output: Path, label: str, force: bool) -> dict[str, Any]:
    command = [str(zimp), "cook", "--source", str(source), "--output", str(output), "--metrics-json"]
    if force:
        command.append("--force")

    start_ns = time.perf_counter_ns()
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    wall_ns = time.perf_counter_ns() - start_ns
    combined = completed.stdout + "\n" + completed.stderr
    metrics: dict[str, Any] | None = None
    for line in combined.splitlines():
        if line.startswith(METRICS_PREFIX):
            metrics = json.loads(line[len(METRICS_PREFIX) :])
    if completed.returncode != 0 or metrics is None:
        print(combined, file=sys.stderr)
        reason = "did not emit metrics" if metrics is None else f"returned {completed.returncode}"
        raise RuntimeError(f"{label} cook {reason}")
    metrics["wall_ns"] = wall_ns
    return metrics


def format_duration(ns: int | float) -> str:
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.2f}s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.1f}ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.1f}us"
    return f"{ns:.0f}ns"


def format_bytes(value: int | float) -> str:
    units = ("B", "KiB", "MiB", "GiB")
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.1f}{unit}" if unit != "B" else f"{amount:.0f}B"
        amount /= 1024
    return f"{amount:.1f}GiB"


def cook_throughput(metrics: dict[str, Any]) -> str:
    cook_ns = metrics["timings_ns"]["cook"]
    source_bytes = metrics["io"]["source_bytes_read"]
    if cook_ns == 0 or source_bytes == 0:
        return "-"
    mib_per_second = source_bytes / (cook_ns / 1_000_000_000) / (1024 * 1024)
    return f"{mib_per_second:.1f} MiB/s"


def other_pipeline_time(metrics: dict[str, Any]) -> int:
    """Return pipeline work not covered by an individually timed stage."""
    timings = metrics["timings_ns"]
    measured_stages = (
        timings["scan"]
        + timings["dependency_graph"]
        + timings["cook"]
        + timings["cache_write"]
    )
    return max(0, timings["total"] - measured_stages)


def print_table(headers: tuple[str, ...], rows: list[tuple[str, ...]]) -> None:
    """Print a plain-text table that remains readable in CI logs and terminals."""
    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    separator = "+" + "+".join("-" * (width + 2) for width in widths) + "+"
    print(separator)
    print("|" + "|".join(f" {header:<{width}} " for header, width in zip(headers, widths)) + "|")
    print(separator)
    for row in rows:
        print("|" + "|".join(f" {cell:<{width}} " for cell, width in zip(row, widths)) + "|")
    print(separator)


def print_results(passes: tuple[tuple[str, dict[str, Any]], ...]) -> None:
    print("\nRESULTS AT A GLANCE")
    print_table(
        ("Scenario", "Total", "Cook", "Wall", "Cooked", "Cached", "Peak allocation"),
        [
            (
                label,
                format_duration(metrics["timings_ns"]["total"]),
                format_duration(metrics["timings_ns"]["cook"]),
                format_duration(metrics["wall_ns"]),
                str(metrics["assets"]["cooked"]),
                str(metrics["assets"]["cached"]),
                format_bytes(metrics["memory"]["peak_allocated_bytes"]),
            )
            for label, metrics in passes
        ],
    )

    cold = passes[0][1]
    warm = passes[1][1]
    invalidated = passes[2][1]
    cold_total = cold["timings_ns"]["total"]
    warm_total = warm["timings_ns"]["total"]
    invalidated_total = invalidated["timings_ns"]["total"]
    cold_peak = cold["memory"]["peak_allocated_bytes"]
    warm_peak = warm["memory"]["peak_allocated_bytes"]
    warm_speedup = cold_total / warm_total if warm_total else 0.0
    invalidation_speedup = cold_total / invalidated_total if invalidated_total else 0.0
    allocation_reduction = cold_peak / warm_peak if warm_peak else 0.0
    print("\nKEY COMPARISONS")
    print(
        f"  Warm cache: {warm_speedup:.1f}× faster than cold; "
        f"{warm['assets']['cooked']} assets recooked; "
        f"{allocation_reduction:.0f}× lower peak allocation."
    )
    print(
        f"  Shared dependency change: {invalidation_speedup:.1f}× faster than cold; "
        f"{invalidated['assets']['cooked']} assets recooked."
    )

    print("\nI/O AND CACHE")
    print_table(
        ("Scenario", "Source read", "Hashed", "Cooked output", "Cache written", "Cook throughput"),
        [
            (
                label,
                format_bytes(metrics["io"]["source_bytes_read"]),
                format_bytes(metrics["io"]["source_bytes_hashed"]),
                format_bytes(metrics["io"]["cooked_bytes_written"]),
                format_bytes(metrics["io"]["cache_bytes_written"]),
                cook_throughput(metrics),
            )
            for label, metrics in passes
        ],
    )

    print("\nTIME ACCOUNTING (total = all stages + other pipeline work)")
    print_table(
        ("Scenario", "Total", "Scan", "Dependencies", "Cook", "Cache write", "Other"),
        [
            (
                label,
                format_duration(metrics["timings_ns"]["total"]),
                format_duration(metrics["timings_ns"]["scan"]),
                format_duration(metrics["timings_ns"]["dependency_graph"]),
                format_duration(metrics["timings_ns"]["cook"]),
                format_duration(metrics["timings_ns"]["cache_write"]),
                format_duration(other_pipeline_time(metrics)),
            )
            for label, metrics in passes
        ],
    )
    print("Other includes cache-session setup and pruning; wall time additionally includes process startup.")

    print("\nMEMORY AND ERRORS")
    print_table(
        ("Scenario", "Peak allocation", "Ending allocation", "Errors"),
        [
            (
                label,
                format_bytes(metrics["memory"]["peak_allocated_bytes"]),
                format_bytes(metrics["memory"]["ending_allocated_bytes"]),
                str(metrics["assets"]["errored"]),
            )
            for label, metrics in passes
        ],
    )


def main() -> int:
    args = parse_args()
    validate_args(args)
    if args.quick:
        args.texture_size = min(args.texture_size, 512)
        args.mesh_grid = min(args.mesh_grid, 128)
        args.materials = min(args.materials, 12)
        args.include_depth = min(args.include_depth, 12)

    repo_root = Path.cwd()
    zimp = Path(args.zimp)
    if not zimp.is_absolute():
        zimp = repo_root / zimp
    if not zimp.is_file():
        raise SystemExit(f"zimp executable not found: {zimp}. Run through 'zig build perf'.")

    work_dir = Path(args.work_dir)
    if not work_dir.is_absolute():
        work_dir = repo_root / work_dir
    ensure_owned_work_dir(repo_root, work_dir)
    source = work_dir / "source"
    output = work_dir / "cooked"
    source.mkdir()
    output.mkdir()

    fixture = generate_fixture(source, args.texture_size, args.mesh_grid, args.materials, args.include_depth)
    source_bytes = bytes_on_disk(source)
    print("zimp performance stress suite")
    print("=" * 29)
    print(f"Fixture directory: {source}")
    print("\nFIXTURE")
    print_table(
        ("Assets", "Source size", "Textures", "Mesh", "Materials", "Include graph", "Direct edges"),
        [(
            str(asset_count(source)),
            format_bytes(source_bytes),
            f"{fixture['textures']} × {args.texture_size}²",
            f"{fixture['meshes']} × {args.mesh_grid}² quads",
            str(fixture["materials"]),
            f"{args.include_depth} levels / {fixture['shader_includes']} files",
            str(fixture["direct_material_edges"]),
        )],
    )
    print("The invalidation pass changes the shared include leaf, then measures all affected recooks.")

    cold = run_cook(zimp, source, output, "cold", force=True)
    warm = run_cook(zimp, source, output, "warm", force=False)
    leaf = source / "shaders" / "includes" / "layer_00.glsl"
    with leaf.open("a", encoding="utf-8") as output_file:
        output_file.write("\n// Changed by the invalidation benchmark.\n")
    invalidated = run_cook(zimp, source, output, "invalidation", force=False)

    passes = (("Cold cook", cold), ("Warm cache", warm), ("Dependency change", invalidated))
    print_results(passes)

    if warm["assets"]["cooked"] != 0 or warm["assets"]["errored"] != 0:
        raise RuntimeError("warm-cache pass did not produce a clean cache hit; results are not trustworthy")
    if invalidated["assets"]["cooked"] == 0 or invalidated["assets"]["errored"] != 0:
        raise RuntimeError("dependency-invalidation pass did not recook assets; results are not trustworthy")

    results = {
        "schema_version": 1,
        "fixture": {
            **fixture,
            "source_asset_count": asset_count(source),
            "source_bytes": source_bytes,
            "texture_size": args.texture_size,
            "mesh_grid": args.mesh_grid,
            "include_depth": args.include_depth,
        },
        "passes": {"cold": cold, "warm_cache": warm, "dependency_invalidation": invalidated},
        "cooked_bytes_on_disk": bytes_on_disk(output),
    }
    result_path = work_dir / "results.json"
    result_path.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\nMachine-readable results: {result_path}")
    print(f"Cooked output on disk: {format_bytes(results['cooked_bytes_on_disk'])}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"stress suite failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
