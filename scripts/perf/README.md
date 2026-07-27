# Local performance stress suite

Run the full suite from the repository root:

```sh
zig build perf -Doptimize=ReleaseFast
```

For a fast validation run:

```sh
zig build perf -Doptimize=ReleaseFast -- --quick
```

The suite generates deterministic assets under `.perf/zimp-stress/`, so the
repository does not need to carry large binary fixture files. The full fixture
contains five 2048×2048 textures, a 384×384-quad OBJ mesh (more than 65K
vertices), 32 materials that fan into the same textures and shader stages, and
a 24-level shared shader include graph.

It measures three useful production scenarios:

- a forced cold cook, for decoding, compression, mesh conversion, allocation,
  output writing, and dependency planning;
- a warm-cache cook, for scan/hash/cache overhead; and
- a leaf-include change, for dependency graph traversal and reverse
  invalidation.

Each pass prints stage timing, wall time, asset/cache counts, peak and ending
requested allocation, source/hash/output/cache bytes, and cook throughput.
The complete structured result is written to
`.perf/zimp-stress/results.json` for plotting or comparisons.

Use `--work-dir`, `--texture-size`, `--mesh-grid`, `--materials`, and
`--include-depth` after `--` to tune the workload. The runner replaces only a
directory that it previously marked as its own fixture directory.
