# ludens-engine

A **test-driven, seam-swappable game-engine core** written in Mojo nightly,
with a geometric-algebra spine: one `Multivector[p,q,r]` generator powers PGA
motors for transforms/skinning, screw-theory rigid dynamics, conformal (CGA)
collision tests, and forward/reverse automatic differentiation.

Two laws govern the codebase (see [docs/CATEGORY.md](docs/CATEGORY.md)):

1. **Every swappable subsystem hides behind a trait** and is chosen at compile
   time — identical game code runs on any implementation, and every seam ships
   with a **parity test** proving the swaps are observationally identical.
2. **Every comparable-method seam has a benchmark row** in
   [BENCHMARK_REPORT.md](BENCHMARK_REPORT.md) — performance claims carry
   measured numbers, never adjectives.

## What's inside

| Subsystem | Seam | Implementations |
|---|---|---|
| ECS storage | `StorageBackend` | sparse-set (EnTT), archetype/SoA (flecs), bitset, reactive (+push observers), naive baseline |
| ECS extras | — | entity relationships (pair store, wildcard queries), command buffers (deferred despawn/relate/**set**), transform hierarchy (matrix & motor propagation) |
| Scheduling | `Scheduler` / `DispatchPolicy` | sequential baseline; **system-as-actor** and **entity-as-actor** (mailbox dataflow) under serial/parallel dispatch — all produce bit-identical worlds (`test_scheduler_parity`) |
| Broadphase | `BroadPhase` | brute force, quad/octree, spatial hash, BVH, **persistent dynamic BVH + pair cache** |
| Narrowphase | `NarrowPhase` / `ManifoldNarrowPhase` | AABB, circle, SAT, OBB, SDF, GJK+EPA (2D/3D with witness points), CGA spheres/planes; **contact manifolds** (clipped patches, per-point depth), rotated box-box (15-axis SAT) |
| Rigid bodies (6-DOF) | `Body6` | `QuatBody6` (quat + inertia tensor) **and** `ScrewBody6` (PGA motor pose + twist bivector, Lie–Poisson) — parity compared **by action**, not coefficients |
| Contact solving | — | Box2D-v3-style sub-stepped soft constraints: warm starting, Coulomb friction, body-frame anchors, joints (ball/distance/hinge), islands + sleeping, speculative **and swept-TOI** CCD |
| Spin integrators | `SpinIntegrator` | semi-implicit Euler, RK2, implicit midpoint, **LGVCI** (Moser–Veselov variational) |
| GA math | `Field` | `Multivector[p,q,r]` (comptime-unrolled products), motors/dual quats, closed-form exp/log, CGA; AD coefficients: `DualReal`, `DualBatch` (4 SIMD lanes), `RevReal` + `Tape` (reverse mode) |
| GPU physics | — | XPBD cloth (gather-Jacobi, CPU/GPU parity ~1e-6) and a VBD prototype, `has_accelerator`-guarded |
| Differentiable sim | — | Field-generic rollouts: gradients through smooth contact, one-tape N-parameter gradients |

Measured highlights (RTX 3060 laptop; context in the report): a 6-box tower
stands 1000 steps with millimetric lean · pendulum period within 0.35 % of
analytic · persistent broadphase 70 µs vs 18.9 ms full rebuild at N=4096 ·
GPU cloth 8.3× CPU at 16k particles · LGVCI holds world angular momentum to
float-roundoff over 20k chaotic-tumble steps.

## Build & run

Linux x86-64 + [pixi](https://pixi.sh). The Mojo nightly is pinned by
`pixi.toml`; every package precompiles into `build/` first (this nightly
resolves cross-file imports only through precompiled packages).

```sh
pixi run build       # precompile all engine packages
pixi run test        # 66 self-checking test programs (stops at first failure)
pixi run examples    # runnable demos (01 movement … 08 wgpu motor skinning)
pixi run benchmark   # regenerate BENCHMARK_REPORT.md
```

Run one thing directly after `pixi run build`:

```sh
pixi run mojo run -I build tests/test_softstep6.mojo
pixi run mojo run -I build examples/06_ga_motor.mojo
```

GPU tests and benches self-skip on hosts without an accelerator. The wgpu
window demo (`examples/08`) additionally needs the native libraries once per
machine:

```sh
curl -fsSL https://raw.githubusercontent.com/Hundo1018/wgpu-mojo/main/scripts/setup-native.sh | pixi run bash
```

## Layout

```
geometry/    vec/mat/quat · GA core (multivector, motors, galie, cga, AD fields) · gjk/epa/sat/clip
collision/   broadphase seams · narrowphase seams · manifolds · dynamic BVH · swept TOI
physics/     6-DOF bodies (quat & screw) · soft-step solver · joints/islands/sleeping ·
             spin integrators · GPU cloth (XPBD, VBD) · differentiable rollouts
ecs/         storage backends · relations · command buffers · observers · transforms
scheduler/   sequential + actor-model schedulers · dispatch policies · fixed loop · seeded RNGs
spatial/     loose quad/octree · hash grid            harness/    test & bench harness
tests/       one self-checking program per seam       benchmarks/ one cross matrix per seam
docs/        CATEGORY (laws) · SOTA_GAP_ANALYSIS · ROADMAP (per-phase progress + numbers)
```

## Honest status

- No restitution yet — every contact scene is e = 0 (boxes land dead).
- 6-DOF solver scenes are box-only; GJK convex hulls exist in the narrowphase
  but are not wired into the solver's shape set.
- The solver is single-threaded (islands are the natural parallel seam, not
  yet exploited).
- No scripting or plugin layer — deliberate: the core API is still moving, and
  host layers will live behind a strict architectural boundary when they come.
- Known Mojo-nightly hazards (bare `List[SIMD3]` teardown corruption, multiple
  `DeviceContext` hang) are root-caused and worked around; details in the
  docs/ progress notes.

Every claim above is backed by a test or a benchmark row — when in doubt, read
[docs/ROADMAP.md](docs/ROADMAP.md): each phase section records what was built,
the gate it passed, and the numbers it produced.
