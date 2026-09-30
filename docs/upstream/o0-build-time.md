# `-O0` does not make shared-library builds faster

## Observation

At `-O0`, Mojo emits 4–5× as many LLVM functions as at the default `-O3`,
and building a shared library is not faster: for this repo's engine it is
38% slower.

| Source | Mojo | `-O3` | `-O0` | ratio | IR functions `-O3` → `-O0` |
|---|---|---|---|---|---|
| hot-reload engine, ~20 exports (n=10) | 1.1.0 | 2.71 s | 3.74 s | 1.38 | 111 → 412 |
| `probe_o0_cost.mojo`, stdlib only (n=5) | 1.1.0 | 2.72 s | 2.80 s | 1.03 | 67 → 309 |
| same | nightly 1.2.0.dev2026093005 | 2.13 s | 2.58 s | 1.21 | 64 → 316 |

Each build used an empty `MODULAR_CACHE_DIR`, 4 vCPU Xeon.

`--mlir-timing` on the engine: at `-O0` the `kgen.generator` pipeline and
`RemoveUnusedParams` do not run, and the later passes (`kgen.func`,
`llvm.func`, `LowerKGENToLLVM`, `AutomaticInline`) each take 3–4× as long.

## Reproduce

```sh
P=experiments/hot_reload/native/probes/probe_o0_cost.mojo
MODULAR_CACHE_DIR=$(mktemp -d) bash -c "time mojo build --emit shared-lib     $P -o p3.so"
MODULAR_CACHE_DIR=$(mktemp -d) bash -c "time mojo build --emit shared-lib -O0 $P -o p0.so"
mojo build --emit llvm     $P -o p3.ll && grep -c '^define' p3.ll
mojo build --emit llvm -O0 $P -o p0.ll && grep -c '^define' p0.ll
```

## Open points before filing

- On the standalone probe the time effect is small (1.03 on 1.1.0). The
  strong numbers come from the engine, which does not build on nightly.
  Need n ≥ 10 on nightly with a larger probe.
- Skipping generator simplification at `-O0` may be intended, for debugging.
  In that case the request becomes a docs note: `-O0` is not a way to
  compile faster.
