# Draft: `-O0` does not make shared-library builds faster, sometimes 20–40% slower

Kind: performance report (issue). Status: draft for review, not submitted.
**Confidence: moderate.** The effect on the IR is large and holds on both
versions. The effect on build time depends on the code.

## Observation

At `-O0`, `mojo build --emit llvm` emits 3.7–4.9× as many functions as at the
default `-O3`. The build of a shared library is then never faster, and for
this project's engine it is 20–40% slower.

| Source | Compiler | O3 build | O0 build | O0/O3 | functions O3 → O0 | n |
|---|---|---|---|---|---|---|
| engine (`engine.mojo`, ~20 exports, reflection-based serialisation) | 1.1.0 | 2.57 s | 3.61 s | **1.40** | 111 → 412 | 10, seed 1 |
| same | 1.1.0 | 2.57 s | 3.61 s | **1.40** | | 10, seed 2 |
| same | 1.1.0 | 3.24 s | 3.88 s | 1.20 | | 5 |
| standalone probe (stdlib only, below) | 1.1.0 | 2.72 s | 2.80 s | 1.03 | 67 → 309 | 5 |
| same | nightly 1.2.0.dev2026093005 | 2.13 s | 2.58 s | 1.21 | 64 → 316 | 5 |

The same engine linked as an executable that calls only 6 exports shows no
difference (1.85 s vs 1.93 s): dead code is removed before lowering.

All builds were uncached (empty `MODULAR_CACHE_DIR`), interleaved, on a
4 vCPU Xeon. Scripts in this repository:
- `experiments/hot_reload/native/compile_speed.py` (R2);
- `compile_speed_followup.py` (R2b);
- `o0_repro.py` (R2c).

## Where the time goes (`--mlir-timing`, engine, 1.1.0, median of 3)

- Passes that do not run at `-O0`: `'kgen.generator' Pipeline` (0.11 s at O3) and `RemoveUnusedParams` (0.08 s).
- Passes that take 3–4× as long:

  | Pass | O3 | O0 |
  |---|---|---|
  | `LowerKGENToLLVM` | 0.03 s | 0.16 s |
  | `'llvm.func' Pipeline` | 0.04 s | 0.16 s |
  | `'kgen.func' Pipeline` | 0.04 s | 0.15 s |
  | `AutomaticInline` | 0.07 s | 0.17 s |
  | `ElaborateGenerators` | 0.12 s | 0.24 s |

- Unattributed "Rest" goes from 0.68 s to 1.25 s.
- MLIR root wall: 2.76 s → 3.56 s.

## Minimal reproduction

`experiments/hot_reload/native/probes/probe_o0_cost.mojo`: four exports using
`List`, `Dict`, `String` formatting and `sort`.

```sh
export MODULAR_CACHE_DIR=$(mktemp -d)
time mojo build --emit shared-lib     probe_o0_cost.mojo -o p3.so
export MODULAR_CACHE_DIR=$(mktemp -d)
time mojo build --emit shared-lib -O0 probe_o0_cost.mojo -o p0.so
mojo build --emit llvm     probe_o0_cost.mojo -o p3.ll; grep -c '^define' p3.ll   # 64
mojo build --emit llvm -O0 probe_o0_cost.mojo -o p0.ll; grep -c '^define' p0.ll   # 316
```

## Why it matters

A developer who wants fast rebuilds (hot reload, edit-compile loops) would
reach for `-O0` and get slower builds. In this project's hot-reload loop the
default is the faster choice.

## Weak points (to settle before filing)

- On the standalone probe the time effect is small on 1.1.0 (1.03) and at
  the bound on nightly (1.21, n=5). The strong numbers come from one engine,
  whose code does not build on nightly (API changes in this repo's
  `ecs.schema`, not in Mojo).
- Needs: n ≥ 10 on nightly with a larger standalone probe (more generic
  instantiations), and an `--llvm-timing` split of the unattributed time.
- It may be intended that `-O0` skips generator simplification (debuggability).
  Then the report becomes a docs request: say that `-O0` is not a
  compile-speed option.
