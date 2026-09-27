# Architecture

This file is the contract that `pixi run arch -- check` (`tools/archindex.mojo`) enforces. Prose here
explains *why*; the machine-readable copy of the layer table lives in
`scripts/arch_layers.toml` and the gate fails the build when the two drift
(the checker reads only the TOML — keep them in the same commit).

## 1. Packages, responsibilities, layers

A package may import only packages in a **strictly lower** layer, plus itself.
Same-layer imports are forbidden (that is how cycles start). `harness` is
test/bench infrastructure: engine packages must never import it.

| Layer | Package | Owns | Must NOT own |
|---:|---|---|---|
| 0 | `diag` | Engine-side observability and the error policy's detect/record/terminate layers: invariant assertions, leveled logging, counters, trace spans, debug-draw command queue, frame arena (Phase 17.9 / 17.10 / 17.32–17.34). Zero engine dependencies, so every package may use it; points are `SIMD[dtype, 4]`, so it needs no `geometry` import | Rendering, file formats beyond a trace dump, any global mutable state |
| 1 | `geometry` | Scalar/vector/matrix math, rotations (quat, motor, dual quat, PGA/CGA/DCGA), coefficient fields for AD, primitive shapes, pairwise geometric tests (GJK/EPA/SAT/clip/SDF/predicates), static BVH + LBVH construction, skinning math | Anything with a time step, a world, or an entity |
| 2 | `numerics` | Sparse matrices, Krylov solvers, flat-vector kernels | Physics meaning of the vectors |
| 2 | `spatial` | Dynamic spatial indexes over AABBs (hash grid, loose quad/octree) | Pair generation policy (that is `collision`) |
| 2 | `procedural` | Noise, animation clips/blending/pose evaluation, gameplay IK | Physics, scheduling |
| 2 | `fluid` | Lattice-Boltzmann (grid fluid) | Particle fluids (those are `physics`) |
| 2 | `ecs` | Entities, components, storage backends, queries, relations, commands, transform propagation | Scheduling of systems |
| 3 | `scheduler` | System scheduling (sequential/job graph/actors/work stealing), fixed-step loop, RNG, FSM | Physics or collision meaning |
| 3 | `collision` | Broadphase seam, narrowphase seam, contact manifolds, CCD/TOI, static level geometry, scene queries | Impulses, integration |
| 4 | `physics` | Every dynamics solver: rigid 2D/6-DOF, articulated chains, constraints, soft bodies, cloth, FEM/MPM/SPH/PBF, differentiable rollouts, serialization of solver state | Gameplay policy (controllers, vehicles, AI) |
| 5 | `gameplay` | Game-facing runtime shell built on physics + collision + ecs: character controller, state interpolation, active ragdoll (Phase 17) | Solver internals |
| 6 | `oop` | The object-oriented baseline engine used only by comparative benchmarks | — |

`harness` (tests/benches), `tests/`, `benchmarks/`, `examples/`, `experiments/`
sit above everything and may import anything.

### Reach-through rule ("上層直接摸到底層實作")

A module outside package `P` may not import an underscore-prefixed name from `P`
(`from geometry.bvh import _Leaf` is a violation). Names beginning with `_` are
package-private implementation. If another package genuinely needs one, the
owning package promotes it to a public name with a docstring — the rename is the
review point. Known, deliberate exceptions are listed in `arch_layers.toml`
under `[allow_private]` with the reason next to each.

### Cycles

Module-level import cycles are forbidden inside a package too, because the
precompile step (`scripts/build_engine.sh`) resolves each package in one pass
and a cycle produces order-dependent build failures.

## 2. Error-handling policy

Mojo gives three mechanisms: `raises` (a typed error that propagates to the
caller), `abort()` (terminate the process now), and `debug_assert` (a check
compiled in only with `-D ASSERT=all`, which the test runner enables; verified
on 1.1.0 that the define reaches code inside precompiled `.mojoc` packages,
and that a failure prints `file:line:col: Assert Error: <msg>` and terminates).
Compile-time switches for the `diag` layer use the same route
(`get_defined_int["LUDENS_LOG_LEVEL", 3]()` + `comptime if`), so a disabled
log level or trace span compiles to nothing. The engine
uses them by **error class**, not by taste:

| Error class | Example | Detected by | Recovered by | Recorded by | Propagates? |
|---|---|---|---|---|---|
| Programmer error / broken invariant | index out of range inside a solver, lane 3 of `Vec3` non-zero, parent handle after child | the layer that owns the invariant, via `debug_assert` (hot path) | nobody — it is a bug | the assert message | **No: terminate.** Tests run with asserts on, so they fail loudly; release builds pay nothing. |
| Invalid caller input at a public API | shape with zero vertices, constraint row of wrong length, unknown entity handle | the public entry point of the owning package | the caller | the caller | **Yes: `raise Error(...)`** at the API boundary; inner code may assume validated input. |
| Environment / resource | no GPU, file unreadable, scene format version mismatch | the adapter that touches the environment (`*_gpu`, `serialize`) | the layer that chose the backend (falls back to CPU, refuses the load) | that same layer, via `diag` counters | **Yes: `raises`** up to whoever selected the backend. |
| Numerical failure | NaN/Inf state, solver divergence, CCD budget exceeded | the solver, once per step (cheap checks at step end, never per iteration) | the solver: quarantine the body (zero velocity, force-sleep) so the world keeps stepping | `diag` counter + event the gameplay layer can read | **No exception** — a world must keep stepping; the count is the signal. |
| Capacity / budget overflow | debug-draw queue full, trace buffer full, contact cache full | the container | the container: drop newest + count drops, or grow if the container is growable | `diag` counter (`dropped_*`) | **No** — never silent: every drop is counted. |

Rules that follow from the table:

1. **Engine packages never `print`.** Output belongs to tests, benchmarks,
   examples, and the `diag` layer's explicit dump functions.
2. **Inner loops never raise.** Validation happens once at the boundary.
3. **`raises` on a signature must be real.** A function marked `raises` only
   because a callee on a `List`/`Dict` path can raise is acceptable; one that
   can never raise should drop the marker when touched.
4. **A recovered numerical failure must be visible in a test**: the test forces
   the failure (NaN injection, divergence) and asserts both that stepping
   continues and that the counter moved.

## 3. Test architecture

Every file in `tests/` declares one tier in a header comment
`# tier: <unit|component|integration|system|stress>`; the runner rejects files
without one. Performance lives in `benchmarks/` (the report is the gate).

| Tier | Scope | Example | Runner |
|---|---|---|---|
| unit | one module, pure functions / one type | `test_vec`, `test_quat`, `test_predicates` | `pixi run test-unit` |
| component | one package seam: every backend/variant of a trait against the same checks | `test_backend_parity`, `test_broadphase` | `pixi run test-component` |
| integration | two or more packages wired together through production entry points | `test_solver_broadphase`, `test_softcouple` | `pixi run test-integration` |
| system | a whole world stepped through the game loop with ECS + scheduler + physics, checked on end state | `test_system_*` | `pixi run test-system` |
| stress | extreme scale / adversarial inputs, slower; run before a release or a solver change | `test_stress_*` | `pixi run test-stress` |
| performance | `benchmarks/bench_*`, collected into `BENCHMARK_REPORT.md` | — | `pixi run benchmark` |

`pixi run test` runs unit → component → integration → system (the fast gate);
`pixi run test-all` adds stress.

Each Phase 17 deliverable carries ordinary / integration / extreme cases (testing
standard v3): ordinary and extreme cases usually live in the unit or component
tier, the integration case in the integration tier.

## 4. The architecture index

`tools/archindex.mojo` (written in Mojo, like the engine; Python is used only
through Mojo's interop for JSON/TOML parsing and to launch `mojo doc`) builds
`build/archindex.json` from two exact sources:

* the **compiler's own declaration dump** (`mojo doc`), which yields every
  struct, trait, function, alias, signature, `raises` flag and trait conformance
  with zero textual false positives, and
* the **import graph**, parsed from `import` / `from … import` statements only
  (not free text), resolved to modules.

Queries (`pixi run arch -- <cmd>`) answer the questions that used to cost a
repository-wide grep: `def NAME` (where is it declared), `impl TRAIT` (every
conforming type = every variant on a seam), `uses MODULE` (who imports it),
`deps MODULE`, `raises PKG`, and `check` (layers, cycles, reach-through). The
measured comparison with grep is in §5.

## 5. Index vs grep (measured)

Reproduce with: `pixi run arch -- bench`. For each query, "grep" is the
command a human or agent would actually type; "index" is the same question
answered from `build/archindex.json` (declarations from `mojo doc`, imports
from the parsed import graph). False positives are grep hits the index
answer doesn't contain; false negatives are index-answer lines grep's exact
command didn't find. Both hit counts and byte counts are post-dedup.

| Query | grep command | grep hits | grep bytes | index hits | index bytes | false+ | false- |
|---|---|---|---|---|---|---|---|
| def BVH | `git grep -n -w BVH -- *.mojo` | 87 | 7137 | 1 | 21 | 86 | 0 |
| def ContactScene6 | `git grep -n -w ContactScene6 -- *.mojo` | 154 | 11836 | 1 | 25 | 153 | 0 |
| def _Leaf (private) | `git grep -n -w _Leaf -- *.mojo` | 34 | 2840 | 0 | 0 | 34 | 0 |
| impl BroadPhase | `git grep -n -w BroadPhase -- *.mojo` | 32 | 2912 | 6 | 159 | 26 | 0 |
| impl StorageBackend | `git grep -n -w StorageBackend -- *.mojo` | 139 | 11319 | 6 | 161 | 133 | 0 |
| uses collision.queries | `git grep -n -F collision.queries -- *.mojo` | 2 | 124 | 2 | 60 | 0 | 0 |
| uses geometry.bvh | `git grep -n -F geometry.bvh -- *.mojo` | 12 | 710 | 12 | 327 | 0 | 0 |
| uses SceneQuery | `git grep -n -w SceneQuery -- *.mojo` | 12 | 957 | 2 | 60 | 10 | 0 |
| uses BoxProxy | `git grep -n -w BoxProxy -- *.mojo` | 154 | 13411 | 29 | 853 | 125 | 0 |
| raises physics | `git grep -n -w raises -- physics/*.mojo` | 62 | 4586 | 52 | 1291 | 32 | 22 |
| deps collision | `git grep -n -e ^from -e ^import -- collision/*.mojo` | 76 | 5186 | 2 | 53 | 74 | 0 |
| deps physics | `git grep -n -e ^from -e ^import -- physics/*.mojo` | 121 | 7539 | 4 | 91 | 117 | 0 |
| **total** |  | **885** | **68557** | **117** | **3101** | **790** | **22** |

Read honestly, not just favorably:

* **The index wins big on "where is X declared / who implements this
  trait" questions** (`def`, `impl`, `raises`-count): 7.6x fewer hits and
  22x fewer bytes overall, because it answers from the compiler's own
  declaration dump instead of matching text. Almost every grep "false
  positive" here is a real usage site — a call, a type annotation, a
  generic bound — that a human has to read past to find the actual
  declaration; `def BVH` and `def ContactScene6` are the sharpest examples
  (86 and 153 usage lines grep can't distinguish from the one real
  declaration).
* **`uses pkg.mod` (module-path form) is a tie.** `uses collision.queries`
  and `uses geometry.bvh` score 0 false positives and 0 false negatives
  both ways: the dotted path is specific enough that grep is already
  exact for this repo's size. The index isn't better here, just no worse,
  and costs a build step grep doesn't need.
* **`def _Leaf` is a real, disclosed index gap, and grep is strictly
  better today.** `mojo doc` omits underscore-prefixed (package-private)
  struct declarations from its own JSON dump entirely, so the index has
  no way to answer "where is `_Leaf` declared" — 0 hits, not "0 relevant
  hits". Grep finds the declaration and all 33 usages in one shot. Fixing
  this would mean falling back to a text scan for leading-underscore
  names specifically, which isn't done yet.
* **`raises physics`'s 22 false negatives are a line-anchor difference,
  not a wrong answer.** Per the spec's own line-resolution rule (source
  3), a declaration's line is always the `def NAME(` line, even when the
  signature wraps and the literal `raises` keyword lands several physical
  lines later. `git grep -w raises` finds the keyword's own line instead.
  Every one of those 22 is the same function, correctly identified, at a
  different (arguably more useful — it's where you'd jump to) line number.
* **`deps` shows the real trade: volume vs. a curated answer.** Grep's
  "what does this package import" is every raw `from `/`import ` line —
  76 for collision, 121 for physics, all of which count as "false
  positives" against the index's answer only because the index instead
  returns the small, deduplicated set of distinct target packages (2 and
  4 respectively) with one evidence line each. That's the actual answer
  to "what does X depend on"; grep's is the input a human would still
  have to summarize by hand.

Headline: across these 12 queries the index returns **7.6x fewer hits**
and **~22x fewer bytes** than the grep a human/agent would actually run,
with false positives concentrated entirely in usage-site noise the index
was built to exclude — and it loses outright on exactly one query
(a disclosed `mojo doc` limitation for private declarations), ties on
literal dotted-path lookups, and differs on `raises` only by which
physical line of an already-correct answer it reports.

_Filled in by the index commit; see `pixi run arch -- bench`._
