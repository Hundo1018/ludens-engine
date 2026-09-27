# Wave A services that do not depend on the solver refactor

17.36 splines · 17.35 timers + tweens · 17.38 event bus · 17.37 entity pools. Each is a new
module with its own seam, parity test and benchmark (架構定律 v2), ordinary / integration /
extreme cases (testing standard v3), a `# tier:` header on every new test file, and it must be
reached by at least one production-style caller or example (定律 v3 "接上專案"). Layering per
docs/ARCHITECTURE.md; `pixi run arch -- check` must stay OK.

**Shared lanes.** Benchmarks and GPU runs are single-lane on this machine (CPU contention skews
numbers; GPU contexts hang when concurrent). Run every benchmark as
`flock /tmp/claude-1000/bench.lock pixi run mojo run -I build benchmarks/<b>.mojo` and every GPU
test as `flock /tmp/claude-1000/gpu.lock ...`. Benchmark numbers on this laptop drift up to ~1.4×
between runs (measured 2026-09-27), so a comparison inside one table is only meaningful when both
sides ran in the same process, interleaved; report ratios, not absolute times, in prose.

## 17.36 Splines — `geometry/spline.mojo` (layer 1)
- Catmull–Rom (uniform / centripetal / chordal as a comptime parameter `alpha`) and piecewise
  cubic Bézier, dimension-generic like `geometry.vec` (`SIMD[WorldType, PadW[dim]]`).
- Evaluation, derivative, arc-length table (N samples; `sample_at_distance(s)` by binary search +
  linear refine), closest point to a query point (coarse samples + Newton on the segment).
- Frames along the curve as PGA motors (`geometry.motor`): rotation-minimising (parallel transport)
  so a vehicle/camera following the path does not twist — the advantage over "position + separately
  computed quaternion".
- Seam + parity: a uniform Catmull–Rom segment P0..P3 IS the Bézier with control points
  P1, P1 + (P2 − P0)/6, P2 − (P3 − P1)/6, P2 → evaluate both at many t: equal within 1e-6.
  Arc-length parity: table length vs dense-sample polyline length.
- Extreme: 2 control points, coincident points (zero-length segment — no NaN tangent), closed loop,
  query exactly on the curve, query at infinity.
- Bench: eval ns/sample per family; arc-length table build vs query; closest-point per query.
- Wiring: an example (`examples/15_*` or later numbering — check what exists) that moves a body
  along a spline at constant speed with a rotation-minimising frame.

## 17.35 Timers — `scheduler/timers.mojo` (layer 3); tweens — `procedural/tween.mojo` (layer 2)
- Timers tick on the FIXED step (tick counts, never wall clock) so they are deterministic and
  replayable. `schedule(after_ticks, id, repeat_every=0) -> TimerHandle`, `cancel(handle)`,
  `advance(n_ticks, mut fired: List[TimerFire])` — fired order is (due_tick, schedule sequence):
  total, deterministic.
- Seam: binary min-heap vs hierarchical timing wheel. Parity: identical fired sequences for a
  randomized schedule/cancel script (seeded `scheduler.rng`). Bench: N active timers
  1e2..1e6 × advance cost (the wheel's advantage regime is large N with near-due timers).
- Tweens: the Penner easing set (linear, quad, cubic, quart, quint, sine, expo, circ, back,
  elastic, bounce × in / out / in-out) selected by a comptime parameter so the dispatch is free;
  `Tween[T]` for `Real`, `Vec3`, and PGA motors (via `geometry.galie` geodesic — screw
  interpolation, the thing lerp+slerp cannot do).
  Tests: e(0)=0, e(1)=1 exactly for every easing; in/out symmetry e_out(t) = 1 − e_in(1 − t);
  motor tween endpoints equal the geodesic endpoints BY ACTION on points (motors M and −M are the
  same motion — compare by action, never by coefficients). Bench: easing eval per family; N
  tweens updated per frame.
- Extreme: zero-duration tween, t outside [0,1] (clamp — document), timer scheduled for tick 0,
  cancel inside the same advance, 1e6 timers due on the same tick.

## 17.38 Event bus — `scheduler/events.mojo` (layer 3)
- Typed channels `Channel[E]` (E: Copyable). Publishers `send(e)`; readers are registered and keep
  a cursor (pull model, Bevy `EventReader` style) — this is Mojo-natural because storing
  heterogeneous closures for push delivery would need type erasure. Events live for two
  `update()` calls (double buffer), so a reader running before or after the writer in a frame
  still sees each event exactly once.
- Determinism: delivery order = send order (sequence number); replaying the same sends gives
  bit-identical reader streams (needed by 17.39 replay and 17.16 rollback).
- Seam: pull (shared buffer + per-reader cursor) vs push (fan-out copy into per-subscriber queues,
  the existing `scheduler/message.mojo` mailbox style). Parity: identical per-reader sequences.
  Bench: readers × events per frame (push costs copies ∝ readers; pull costs cursor checks).
- Extreme: reader registered mid-frame (sees only later events — document), reader that never
  reads (buffer still recycles after 2 updates; count dropped-unread in a `diag` counter),
  0 readers, 1e6 events in one frame.
- Wiring: contact events from the solver (`collision.contact_events.ContactEvent`) published on a
  channel by a small adapter, with a test that a reader receives began/ended.

## 17.37 Entity pools — `ecs/pool.mojo` (layer 2)
- Pre-spawn N entities with a template component set; `acquire()` returns a live entity with the
  template values, `release(e)` returns it without despawning (no archetype migration / no id
  churn). Disabled entities must be invisible to queries — pick the mechanism per backend that
  keeps queries unchanged (e.g. a `Disabled` marker component excluded by the query path, or
  moving to a dormant storage); document it.
- Seam: direct spawn/despawn vs pool acquire/release, across all six ECS storage backends.
  Parity: after acquire, component values equal a freshly spawned entity's; queries return the
  same set. Bench: churn throughput (acquire/release vs spawn/despawn) N=1e3..1e5 per backend —
  and the N=1 control must be slightly SLOWER for the pool (otherwise the wide rows are suspect).
- Extreme: pool exhausted (grow or refuse — document; count it), double release (programmer
  error → debug_assert), release of a non-pool entity, stale handle after release (generation
  must detect it).
