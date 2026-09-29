# Architecture / responsibility audit — before Phase 17 Wave A/B

Date 2026-09-27. Read-only audit of the working tree on `dev` (toolchain migration in
flight; `@parameter`/`capturing` churn ignored). Nothing was built or run: every
runtime behaviour below marked **(by reading)** is derived from the cited code, not
observed. Line numbers refer to the working tree at audit time.

Severity legend
- **block-before-WaveA**: building any Wave A item on top first would either violate the
  layer/reach-through contract or force rework of the new code.
- **fix-alongside**: do it as the *first commit of the named Phase 17 item*, not after it.
- **note**: record it; no ordering constraint.

Method: module import graph from `from …/import …` lines of every engine module
(Tarjan SCC → **0 module-level cycles**; 10 underscore imports), per-module importer
lists (`grep -rl` over tests/benchmarks/examples/engine), and full reads of
`physics/solver6.mojo`, `physics/serialize.mojo`, `collision/{broadphase,pipeline,queries,toi,bp_bvh}.mojo`,
`procedural/anim.mojo`, `scheduler/{fsm,gameloop,scheduler}.mojo`, plus targeted reads elsewhere.

---

## 1. Responsibility maps

### 1.1 `physics/solver6.mojo` (2038 lines) — verdict: god module, 11 clusters

| # | Cluster | Lines | What it does | Proposed destination |
|---|---|---|---|---|
| 1 | Contact constraint record | 50-51, 54-93 | `_BETA/_SLOP`; `_CPair` = pair ids + feature key + manifold + 4 accumulators + anchors + restitution prep | `physics/contact6.mojo` as public `ContactConstraint` (serialize needs it: serialize.mojo:18) |
| 2 | Contact events | 96-161, 275-280, 916-963 | `ContactEvent`, 21-bit key packing `_ckey`, private merge sort, began/stay/ended diff | `collision/contact_events.mojo` (pure set diff over (a,b,feat); sensors need it without impulses). Replace `_sort_keys` with stdlib sort after a probe |
| 3 | Vector helpers | 164-178 | `_cross`, `_tangent_basis` | `geometry/vec.mojo` public `cross`, `tangent_basis` (see F8) |
| 4 | Joints | 188-229, 1075-1223 | `Joint6` (ball/distance/hinge), scalar axis solve, sweep, warm start | `physics/joints6.mojo` |
| 5 | Scene state + registration API | 232-313, 403-501, 592-593 | 20 fields = 13 per-body parallel lists + side tables; `add*`, `set_filter/sensor/restitution` | stays in `solver6.mojo`, but per-body lists become one `BodySet` (F5) and collider data moves to cluster 6 |
| 6 | **Collider registry + narrowphase dispatch** | 244-274 (fields), 503-590, 642-740 | shape kinds, hull/mesh/heightfield side tables, category/mask, sensor flag, `_should_collide`, `_mesh_*`, `_as_hull`, `_hull_faces`, `_axes`, `_pair_manifold`, `_fat_aabb` | **`collision/collider_set.mojo`** (F1). Collision-layer responsibility living in layer 3 |
| 7 | **Contact generation + broadphase** | 742-914, 965-1021 | per-pair speculative margin, mesh multi-manifold, sensor overlap collection, warm-start match, brute O(n²) or **inline throwaway BVH** (984-1014) | detection → `collision/contact_gen.mojo` over the `BroadPhase` seam (F2); prep/warm-start match → `physics/contact6.mojo` |
| 8 | Contact solve | 595-596, 1023-1045, 1225-1246, 1282-1388, 1446-1495 | warm start, soft (Box2D v3) normal+friction solve, restitution pass | `physics/contact6.mojo`, written against a body view, not `self` (prerequisite for 17.17 GPU seam and 17.20 `Field` genericity) |
| 9 | Legacy one-shot path | 598-640, 1047-1073 | `_solve_point` + `step` (ignores joints, soft bodies, sleep, restitution, events) | keep behind `contact6` or retire; used only by tests/test_solver6.mojo:26,38 |
| 10 | Islands, sleep, colouring, parallel | 315-401, 1119-1120, 1248-1280, 1773-1813, 1853-1921, 1971-2038 | union-find, island wake/sleep, graph colouring (inline in `step_soft`), island partition, `parallelize` fan-out | `physics/islands.mojo` (takes an edge list, so it does not import contact6) + `physics/coloring.mojo` |
| 11 | CCD | 1390-1444 | all-pairs swept-box TOI clamp | `physics/ccd6.mojo`, consulting `ColliderSet` for kinds/filters (F4) |
| 12 | Soft-body pass + coupling | 1497-1771 | XPBD predict (1530-1550), edge solve (1551-1570), particle-vs-shape pushout + sweep + friction + reaction impulse (1571-1765), velocity finalize (1766-1771) | lattice ops → methods on `SoftBody` (softbody.mojo); particle-vs-shape query → `ColliderSet` (collision); impulse coupling → `physics/soft_couple.mojo` |
| 13 | Orchestration | 1815-1968 | `step_soft`: 11 parameters, colouring, partition, serial substep loop, events, cache | stays: `solver6.mojo` becomes ~250 lines of composition + a `SolverConfig` struct |

Resulting physics-internal DAG (acyclic): `solver6 → {contact6, joints6, islands, coloring, ccd6, soft_couple, body_set}`; `contact6, joints6 → body_set (Body6)`; `islands` takes `(a,b)` edges only. Collision gains `collider_set`, `contact_gen`, `contact_events`; physics imports them (layer 3 → 2, legal).

### 1.2 `physics/chain.mojo` (1147 lines) — verdict: over-scoped at the edges, core is cohesive

| Cluster | Lines | Proposed destination |
|---|---|---|
| Private 3×3 matrix library (`_Rows3`, `_matvec`, `_rot_rows`, `_skew`, `_matmul`, `_transpose`…) + `_cross` | 29-60, 1034-1115 | `geometry` linear `Mat3x3`/`Rot3` (geometry's `Mat3` is a 2-D affine: geometry/mat.mojo:7-8) |
| Spatial inertia `SpInertia`, `_ABI` | 63-100, 148-178, 1117-1147 | `physics/spatial_inertia.mojo` (shared by floating.mojo:36) |
| Model: `ChainLink`, `Chain`, FK | 102-146, 180-252 | stays |
| Dynamics: RNEA, CRBA (fixed + floating), ABA | 254-568, 609-620, 885-1007 | stays (this is the module's reason to exist) |
| **Dense linear solve** `solve_h` | 571-607 | `numerics/dense.mojo` (Cholesky: H is SPD; report singularity; see hotspot E18) |
| Contact coupling: point Jacobian + impulses | 631-718 | `physics/chain_contact.mojo` |
| **Ad-hoc ground plane** `resolve_ground` (`floor_y`, fixed `up=(0,1,0)` at 755) | 720-793 | same module, but against `ColliderSet` queries; 17.2 active ragdoll cannot stand on a trimesh otherwise |
| Joint limits | 795-876 | stays |
| Integrators + energy diagnostic | 878-883, 1002-1032 | stays |

Coupling defect: `FloatingChain` drives `Chain` through its public mutable `base_w/base_v/base_wa/base_va` fields, saving and restoring them around calls (physics/floating.mojo:97-98, 125-176, 193-194). Two copies of the base velocity (FloatingChain.base_w and Chain.base_w) are synchronized by hand. This is hidden temporal coupling; pass the base motion as a parameter. It blocks 17.18 batching and 17.20 differentiation of articulated bodies.

### 1.3 `collision/manifold.mojo` (640 lines) — two unrelated halves

- 44-100 `ContactManifold` type; 101-233 the 2-D/generic `ManifoldNarrowPhase` seam with four registries. Only tests/test_manifold.mojo, tests/test_quickhull.mojo and benchmarks/bench_manifold.mojo use it.
- 235-640 3-D analytic manifolds (box/sphere/capsule), `Axes3` (244). Used by solver6 (36-45) and toi (24).
- Split into `manifold.mojo` (type) / `manifold_np.mojo` (seam) / `manifold3.mojo` (analytic). Severity: note.

---

## 2. Findings

| id | severity | path:line | problem | proposed fix | effort |
|---|---|---|---|---|---|
| F1 | **block-before-WaveA** | physics/solver6.mojo:244-274, 503-590, 642-740 | The collider registry (shape kinds, hull/mesh/heightfield tables, filters, sensors) and the shape-pair dispatch live inside `ContactScene6` (layer 3). 17.13 shape queries (collision, L2) cannot import physics. 17.1 controller (gameplay, L4) would have to read `sc.shape/half/hull_id/meshes`, which is the reach-through the contract forbids. | Extract `collision/collider_set.mojo`: collider data plus `pair_manifold(i, j, pose_i, pose_j, margin)`, `fat_aabb`, `as_hull`, and mesh candidates. Poses (pos + `Axes3`) are passed in, so collision never sees `Body6`. `ContactScene6` then *holds* a `ColliderSet`. | L |
| F2 | **block-before-WaveA** | physics/solver6.mojo:32, 984-1014; physics/step.mojo:13-15 | The 3-D solver ignores the `BroadPhase` seam. It imports `geometry.bvh` directly and builds a BVH per step that it then discards. The six `BroadPhase` backends and `CollisionPipeline` have one production consumer, the legacy 2-D `physics/step.mojo`; everything else is tests and benches. So the seam benchmarks measure a path the engine never runs, and 17.13 queries would build a third index. | `ContactScene6[B, BP: BroadPhase]` with a persistent broadphase owned by the collision world. `contact_gen` enumerates through it and scene queries reuse it. The parity test (`test_solver_broadphase`) becomes a seam parity row. | M |
| F3 | **block-before-WaveA** (bug) | physics/solver6.mojo:466-468, 481-483, 738-739 vs 255-258 | The docstring says a static mesh's body pose is ignored. But `add_trimesh`/`add_heightfield` record only `bounds().half_extents()`, and `_fat_aabb` centres the box on `bodies[i].position()`. **(by reading)** With `broadphase=True`, level geometry whose bounds are not centred on the body pose is culled: bodies fall through, and the brute and BVH paths disagree, which breaks the parity claim at 976-980. Tests only use origin-centred meshes (tests/test_trimesh.mojo:57-58); the bowl case (119-146) runs brute only. | Store the world AABB of static colliders explicitly. `fat_aabb` returns it for kinds 4/5. Add a test with an off-centre heightfield and `broadphase=True`. | S |
| F4 | **block-before-WaveA** (bug) | physics/solver6.mojo:707-713, 848-870, 1575-1583, 1412-1437 | The shape-kind dispatch has silent catch-alls. (a) `_pair_manifold`'s `else` treats every unknown kind as capsule-capsule; sensor-vs-mesh reaches it because the sensor branch (848) runs before the mesh branch (868). (b) `_softbody_pass` treats every non-box kind, including hull, trimesh and heightfield, as a sphere of radius `half.x` at the body position; for a level mesh that is a sphere the size of the level. (c) `_ccd_advance` sweeps every body as its `half` box (level bounds included) and ignores `_should_collide` and sensors. **(by reading)** No test combines `ccd=True` with a mesh (grep). | Make the dispatch exhaustive over kinds, with `abort` on unsupported kinds. Reject unsupported combinations at the API (`raise` in `step_soft(ccd=True)` when kinds 3-5 are present, until a TOI for them exists). Route the soft-particle and CCD shape tests through `ColliderSet`. | S-M |
| F5 | **block-before-WaveA** | physics/solver6.mojo:235-280, 403-417; physics/serialize.mojo:195-242, 306 | Body identity is a raw index into 13 parallel lists, with no removal and no stable handle. `serialize` re-implements `add` by appending to each list directly, so a new per-body list added to the scene but not to serialize silently misaligns the lists. `statics: List[Bool]` (54 references) cannot express kinematic bodies (17.24). | `BodySet` SoA struct with a single `push`, a `BodyId` newtype, a motion-type enum {static, kinematic, dynamic} and materials. Add a `snapshot()/restore()` API that solver6 owns and serialize calls. Must land **before gameplay code stores body indices** (17.1 ground/platform refs, 17.7 interpolation buffers). | M |
| F6 | **block-before-WaveA** (contract) | docs/ARCHITECTURE.md §1 (`diag` = layer 0, `geometry` = layer 0); geometry/vec.mojo:14-46 | The proposed contract is self-blocking. Same-layer imports are forbidden, so `diag` (L0) cannot use `Vec3`, yet 17.9 debug-draw needs points. `diag` cannot move up either: fluid and numerics (L1) must record numerical failures through it (§2 table). `WorldType` is also re-hardcoded as float32 at ecs/system.mojo:28 and serialize.mojo:24-25, plus 4 GPU modules. | New layer-0 `core` holding only the scalar/vector aliases (`WorldType, Real, Vec2, Vec3, PadW, vlanes`). Move geometry and `diag` to layer 1 and shift the rest up by one. Keep `geometry.vec` as a re-export; probe that re-export resolves before moving (≤10-line probe). This gives one switch for 17.8 f64. | S (TOML/doc) + M (move) |
| F7 | fix-alongside (before 17.6) | scheduler/fsm.mojo:1-17; procedural/anim.mojo:1, 235-314 | The FSM sits in `scheduler` (L2) while the animation graph (17.6) is slated for `procedural` (L1), which cannot import it. The FSM has zero imports and zero engine users (only tests/test_fsm.mojo). See §3(c). | Move to `procedural/fsm.mojo`. Fix the anim.mojo:1 docstring. | S |
| F8 | **block-before-WaveA** | 3-D cross product re-implemented privately in 11 modules: geometry/epa.mojo:189, gjk.mojo:93, quat.mojo:15; collision/toi.mojo:33, manifold.mojo:235; physics/floating.mojo:39, rigid6.mojo:33, integrator6.mojo:34, chain.mojo:29, sensors.mojo:84, solver6.mojo:164. Also `_tangent_basis` (solver6.mojo:173) vs `_basis` (collision/hull.mojo:219), `_det3` (fem.mojo:32, reached by mpm.mojo:31), and chain's `_Rows3` library | `geometry` lacks `cross`, `tangent_basis`, and a linear 3×3 type (geometry/mat.mojo:7-8: `Mat3` is a 2-D affine). The 17.1 controller, 17.3 IK and 17.7 interpolation will add copies 12-14. | Public `cross`, `tangent_basis`, `Mat3x3` (`matvec`, `det`, `skew`, `transpose`) in geometry; migrate the copies opportunistically. | S-M |
| F9 | **block-before-WaveA** | docs/ARCHITECTURE.md §1 ("`scripts/archindex.py check` enforces"), §3; `ls scripts/`, no `tools/` | The contract is unenforced. Neither `scripts/archindex.py` nor `tools/archindex.mojo` exists. 0 of 116 `tests/*.mojo` carry the `# tier:` header the runner is said to reject. The one cross-package violation, collision/bp_bvh.mojo:5 `_Leaf`, is trivially fixable: `BVH.build_boxes` already exists (geometry/bvh.mojo:371-380) and `BVH.build` exposes the private type in a public signature (bvh.mojo:45-47). | Land a minimal import-graph gate (layers + cycles + `_` reach-through) before Wave A code. A ~60-line prototype over this tree reports 0 cycles and 10 underscore imports (listed in F18). Change bp_bvh to call `build_boxes` and make `build` private. | S |
| F10 | **block-before-WaveA** (for APIs Wave A touches) | grep over engine packages: 0 × `debug_assert`/`abort`, 0 × `isnan/isfinite`, 4 × `raise Error` (serialize.mojo:179, constraints.mojo:86, tendon.mojo:208, chain.mojo:217) | Error policy §2 has no implementation. The programmer-error class has no asserts, and the numerical-failure class has no detection, so NaN bodies step forever. Public constructors turn bad input into UB or NaN (§4). | Order: 17.33 assert layer, then boundary `raise` in `ContactScene6.add*`, `add_joint`, `step_soft(substeps, hertz)`, `TriMesh`, `HeightField`, then the end-of-step NaN quarantine plus a `diag` counter, with a test that injects NaN. | M |
| F11 | fix-alongside (first commit of 17.17 / 17.18 / 17.20) | physics/solver6.mojo clusters 4, 8, 10-12 (§1.1) | Contact solve, joints, islands/colouring, CCD and soft coupling are all methods on `ContactScene6` that read `self.bodies/statics/island` directly (124 `self.bodies[` sites). 17.17 needs a CPU/GPU contact-solver seam, 17.18 needs world state as batchable SoA, 17.20 needs the solve generic over `Field`. Each is a rewrite of a 2038-line file if done before the split. | Split per §1.1 into free functions over a body view plus a constraint slice. The existing `_solve_islands_parallel` (1971) is already that shape. | L |
| F12 | fix-alongside (before 17.2) | physics/chain.mojo:571-607, 720-793; physics/floating.mojo:97-98, 125-176 | Chain is over-scoped (§1.2): a dense solver belongs in numerics, ground contact belongs in collision, and FloatingChain mutates Chain's hidden state. | See §1.2. | M |
| F13 | fix-alongside | physics/chain.mojo:224 (`fk`), 256, 310, 320, 334, 393, 403, 461, 609, 631, 638, 669, 678, 700, 728, 795, 862, 878, 887, 1002, 1009; physics/{sensors,tendon,floating,constraints}.mojo; geometry/quickhull.mojo:37, 75 | These `raises` can never raise: nothing in `fk`, the RNEA/CRBA/ABA sweeps or quickhull raises. It spreads through ~35 signatures, in breach of rule §2.3. | Drop the markers. Keep `raise` only at `add_link_to`, `constraints.add` and `tendon.wrap_last`. | S |
| F14 | fix-alongside (17.37 / 17.33) | ecs/sparse_backend.mojo:100-110; ecs/archetype.mojo:268-299; ecs/entity.mojo:1-5 | `get/set/has/remove` ignore `Entity.gen`. A stale handle silently reads or writes the recycled entity, which contradicts entity.mojo's "stale copy can be detected". | `debug_assert(is_alive(e))` in `World` accessors (ecs/world.mojo) plus a raising `try_get`. | S |
| F15 | **block-before-WaveA** (decision) | scheduler/scheduler.mojo `System.apply[B](mut world)` (stateless, World-only); ecs/world.mojo (no resources); grep: no `ContactScene6` in ecs/scheduler | There is no home for stateful runtime. A physics world cannot be a system or a component, and nothing syncs `ContactScene6` poses to ECS transforms. 17.1 and 17.7 ("接 gameloop + ECS transform") need one. The only physics→ECS glue today is legacy: physics/integrator.mojo, and physics/screw.mojo:45, 60. The production rigid6 path imports `ecs` transitively only because `screw_velocity` shares a module with an ECS system (rigid6.mojo:30 → screw.mojo:17-19). | `gameplay/runtime.mojo` (L4) owns `World + ContactScene6 + FixedLoop` and the pose→transform sync system. Move `ScrewBody/integrate_screw` there and keep `screw_velocity/step_screw` in physics. | S decide / M build |
| F16 | fix-alongside (17.7) | scheduler/gameloop.mojo:33-37 | When `max_steps` clamps, the accumulator is not drained, so `alpha` can exceed 1 and debt grows without bound. With `dt=0`, `alpha = inf`. 17.7 interpolates with this `alpha`. | Drop excess debt when clamped and count the drop (policy: capacity class). Assert `dt>0`. | S |
| F17 | fix-alongside (before 17.17) | geometry/gpu_lbvh.mojo:30-35; physics/gpu_cloth.mojo:323-333; physics/vbd_cloth.mojo:361-368 | The layer-0 package pulls in `max.gpu` and `layout` via an unwired module (only tests/test_gpu_lbvh.mojo and benchmarks/bench_gpu_lbvh.mojo use it). Engine API functions create their own `DeviceContext()` although the module docstring records that multiple contexts hang (gpu_cloth.mojo:327-330). 17.17 GPU rigid + GPU cloth in one frame would hit that. | Move `bvh.mojo` + `gpu_lbvh.mojo` to `spatial` (§3(b)). Pass one device context from a single owner (`*_ctx` variants only) and drop the ctx-creating wrappers from engine API. | M |
| F18 | fix-alongside | physics/serialize.mojo:18-19 (`_CPair`, `_SP`, `_SEdge`); physics/vbd_cloth.mojo:29 (`_init_grid`); physics/mpm.mojo:31 (`_det3`); physics/sph.mojo:29 (`_H`); geometry/gmv.mojo:12 (sign tables); ecs/system.mojo:42-49 (`_slot_of`, `_col`); physics/softbody.mojo:43-44 (public `List[_SP]`) | Intra-package reach-through into private names, including public fields typed by private structs. `sph` shares PBF's kernel radius constant, which couples SPH resolution to a PBF module constant. | Promote each to a documented public name, or move it to its user. Make `_H` a per-fluid field. | S |
| F19 | fix-alongside (17.23 / 17.25) | physics/solver6.mojo:724 and 838 (`SPEC_BASE` twice), 50-51, 373-375, 1452, 1815-1829 | The fat-AABB/margin parity guarantee (720-723) depends on two separate literals staying equal. Tuning constants are compile-time and `step_soft` takes 11 positional flags. Friction is a global `mu` (1823), which 17.23 must replace. | One `SolverConfig` struct holding margins, sleep thresholds, restitution threshold and the default material. Define `SPEC_BASE` once. | S |
| F20 | fix-alongside (17.40) | physics/serialize.mojo:24-25, 53-56, 69-174 vs solver6.mojo:278-280 | The snapshot claims bit-identical continuation (1-8) but omits `_prev_keys`/`events_on`, so the event stream differs after load. The float format is hard-coded Float32. `_Reader.i` reads past the end on truncated input (out-of-bounds read instead of `raise`). Body and joint indices are not validated. | Fixed by F5's snapshot API. Add bounds-checked reads that `raise`, and validate indices on load. | S |
| F21 | note | physics/{solver,step,rigidbody,forces,body,integrator}.mojo | The legacy 2-D cluster is not wired: see §3(d). | Freeze it. Mark it "comparison baseline, no new dependents" in ARCHITECTURE.md and exclude it from 17.23's material unification. Retiring it needs the user's call (iron rule 6). | S |
| F22 | note (input to 17.19) | physics/solver6.mojo:362-369, 387-401, 815-826, 902-913, 1406-1437, 1795-1810, 1905-1910, 1856-1880 | Quadratic hot spots at scale: island wake and sleep O(n²); warm-start match does a linear cache scan per pair; CCD checks all pairs; partition is O(islands × pairs); `_solve_island` scans all bodies per island per substep. The 64-colour cap is unchecked (`1 << col` on Int). | Fix these during the F11 split. Add a stress row at 1e4 bodies. | M |
| F23 | note | physics/solver6.mojo:1889 | `parallel=True` silently falls back to serial when soft bodies or `ccd` are present. | Count it (diag) or reject it at the API. | S |
| F24 | note | collision/manifold.mojo:101-233; geometry/clip.mojo (only user: collision/manifold.mojo:38) | Seam variants used only by tests/benches sit in the production module. Contact clipping is a collision responsibility living in geometry. | See §1.3. Move `clip.mojo` into collision. | S |
| F25 | note (17.27 / 17.28) | physics/fem.mojo:294 (`floor_y`); physics/chain.mojo:720; physics/gpu_cloth.mojo:29, vbd_cloth.mojo:32 (`_G = -9.8`); `cpu_cloth_run` / `gpu_vbd_run` whole-rollout APIs | The deformable solvers each carry their own floor and gravity and expose rollout-shaped APIs. There is no shared world or step contract, so force fields and buoyancy have nothing to attach to. | Define a minimal `step(dt, gravity, colliders)` contract when 17.27 starts. | M |

---

## 3. Verdicts on the suspicions

**(a) solver6 is a god module: confirmed.** §1.1 maps 13 clusters. Two of them are not physics at all:
- cluster 6, the collider registry and dispatch (belongs in collision);
- cluster 2, the event diff (pure set logic).

The file also carries its own sort (122-161), cross product (164) and BVH broadphase (984-1014).

**(b) Should geometry split into math / pairwise tests / acceleration structures? Only the acceleration structures should move; a 3-way split does not pay.**
- *A full split creates problems.* `spatial` (L1) imports `geometry.aabb` (spatial/tree_core.mojo:13, spatial/hash_grid.mojo:12). If AABB moves to a "shapes" package above math, `spatial` has to move up a layer, and so does everything that imports it. It churns importers across 4 packages, and removes no cycle (there are none) and no leak.
- *Math and pairwise tests together are consistent with the contract.* Both are stateless functions of geometry with no time step, world or entity, which is exactly the layer-0 charter. The only misfiled pairwise-test module is `clip.mojo`, a contact-manifold clipper whose single user is collision/manifold.mojo:38 (F24).
- *The acceleration structures should move to `spatial`.*
  - `bvh.mojo` imports only `.vec/.aabb/.ray` (bvh.mojo:9-11), so it moves up cleanly.
  - `gpu_lbvh.mojo` drags `max.gpu` + `layout` into the root package (gpu_lbvh.mojo:30-35), which matters for the wasm-retarget path, and nothing in the engine uses it.
  - Every current `geometry.bvh` importer sits at layer ≥2: collision/bp_bvh, queries, trimesh; physics/solver6 (which should go through collision per F2).
  - `spatial`'s charter is already "spatial indexes over AABBs". Today the indexes are split three ways: static BVH in geometry, dynamic BVH in collision/bp_dbvh.mojo, grid and tree in spatial.
  - Net effect: GPU leaves layer 0 and the indexes get one home, at no cycle risk. Effort M, sequenced as F17.

**(c) `procedural/anim.mojo` "state machine" vs `scheduler/fsm.mojo`: there is no duplication, but the docstring is wrong and the placement blocks 17.6.**
- anim.mojo:1 promises "a state machine driving them". No state machine exists in the file: `AnimPlayer` (235-314) is a cross-fader driven by `play(clip)`, and its own docstring (240-241) says the state machine lives elsewhere.
- `StateMachine` (scheduler/fsm.mojo:18) has no imports and no engine user; only tests/test_fsm.mojo uses it.
- Under the proposed layers, the 17.6 animation graph in `procedural` (L1) cannot import `scheduler.fsm` (L2). The fix is to move the FSM down (F7).
- Related placement issue: the contract gives `procedural` "gameplay IK". Two-bone/FABRIK/look-at are pure geometry and fit there. **Foot planting** needs ground raycasts (collision, L2), so it must live in `gameplay` (L4).

**(d) The legacy 2-D physics path is not wired to anything but tests and benches.**
- `solver.mojo`, `step.mojo`, `rigidbody.mojo`, `forces.mojo` are used only by benchmarks/bench_physics.mojo and tests/test_physics_dynamics.mojo, plus each other.
- `body.mojo` and `integrator.mojo` are used only by tests/test_physis.mojo. The mentions in ecs/transform_systems.mojo:12 and physics/screw.mojo:14 are docstrings.
- This cluster is the only production consumer of `collision/pipeline.mojo` and `AABBNarrowPhase` (step.mojo:13-15).
- It also hosts the second, inconsistent material rule cited by 17.23 (solver.mojo:85, 101).
- Recommendation: freeze it (F21). Deleting it means removing the only real consumer of the `CollisionPipeline` seam, so decide that together with F2.

**(e) Module-level import cycles: none.** Tarjan SCC over every engine module's imports found no component larger than 1. The package DAG matches the one in the brief.

**(f) Reach-through inside packages: yes.** The ten underscore imports are listed in F18. The heaviest structural coupling is not an underscore import:
- serialize.mojo mutates all 13 of `ContactScene6`'s parallel lists directly (F5);
- floating.mojo drives `Chain` through mutable fields (§1.2);
- ecs/system.mojo reaches into `ArchetypeBackend._slot_of/_col` (42-49). Its comment at 26-28 ("kept local so ecs stays independent of geometry") is stale, because ecs/transform.mojo:19-21 already imports geometry.

**(g) Error handling: see §4.** The pattern is uniform: **invalid input and numerical failure both become silent NaN, UB or wrong results**. There is no assert layer and no NaN detection. Two exemplars to copy:
- numerics/cg.mojo:39-56, `CgResult` with `converged`/`stalled`. Even its one caller, fem.mojo:273-287, applies `dv` before looking at the result.
- collision/bp_gpu.mojo:83-88, which returns `False` on capacity overflow instead of silently truncating.

---

## 4. Error-handling hotspots (what happens on bad input today)

| # | path:line | Input | Today (by reading) | Policy class → fix |
|---|---|---|---|---|
| E1 | physics/rigid6.mojo:143-144, 258-259, 163; solver6.mojo:403-417, 1051/1797/1925 | dynamic body with `mass = 0` | `inv_mass = inf`; gravity force `g / inf = 0`; `force * (dt/mass) = 0·inf = NaN` → NaN pose, stepped forever | invalid input → `raise` in `add` |
| E2 | physics/rigid6.mojo:84-85 | `Inertia3` with a zero principal moment (thin rod) | `l / ix = inf` angular velocity | invalid input → `raise` |
| E3 | physics/solver6.mojo:1658, 1760 (vs 1561, which supports `w = 0`) | pinned soft particle (`w = 0`) touching a dynamic body | reaction impulse `-(1/p.w)` = inf | invariant → skip coupling when `w == 0` |
| E4 | physics/softbody.mojo:70, 75-77, 82, 107, 114 | `box_lattice(n=1)` / `n=0`; empty body | 0/0 NaN positions, radius inf; `per = inf`; `top_y` indexes `pts[0]` on empty | invalid input → `raise n < 2` |
| E5 | physics/solver6.mojo:1845-1850 | `step_soft(substeps=0)`, negative hertz/zeta | `h = inf` → NaN everywhere | invalid input → `raise` |
| E6 | physics/solver6.mojo:116-119, 955-963 | body or triangle index ≥ 2²¹ | event keys alias silently | capacity → assert at `add`/mesh build |
| E7 | physics/solver6.mojo:1856-1880 | a body in ≥ 64 differently-coloured pairs | `1 << 64` on Int → wrong colours → same-colour pairs share a body → data race under `colored+parallel` | capacity → fall back + count |
| E8 | physics/solver6.mojo:848-866 → 707-713 | sensor overlapping a trimesh/heightfield | capsule-capsule test on mesh bounds → garbage overlap/events | F4 |
| E9 | physics/solver6.mojo:1575-1583 | soft body near a hull/mesh/heightfield | treated as a sphere of radius `half.x` at the body pose | F4 |
| E10 | physics/solver6.mojo:466-468, 738-739 | level mesh not centred on its body pose, `broadphase=True` | contacts culled; bodies fall through; brute ≠ BVH | F3 |
| E11 | physics/solver6.mojo:1412-1437 | `ccd=True` with meshes, sensors or filtered pairs | motion clamped at level bounds / trigger volumes / non-colliding bodies (untested) | F4 |
| E12 | physics/solver6.mojo:311-313, 489-501, 592-593 | bad index in `add_joint/set_filter/set_sensor/set_restitution`; `e ∉ [0,1]` | out-of-bounds write (UB in release); restitution unchecked | invalid input → `raise` |
| E13 | collision/trimesh.mojo:79-108, 179-190 | index ≥ vertex count; `len % 3 ≠ 0`; `len(heights) ≠ nx·nz`; `cell ≤ 0` | out-of-bounds read; silent truncation; OOB in `_corner` | invalid input → `raise` |
| E14 | geometry/sat.mojo:56-61; geometry/shape.mojo (Polygon ctor) | polygon with a duplicate consecutive vertex / non-convex / CW | zero axis → overlap 0 → reports **miss** for overlapping shapes; contract never checked | invalid input → validate at construction |
| E15 | geometry/quickhull.mojo:84-89 | < 3 points, all points equal | degenerate 1-2 vertex "polygon" returned; fn is `raises` but never raises | invalid input → `raise` (makes the marker real) |
| E16 | geometry/vec.mojo:83-87 → scheduler/rng.mojo:130, 134; geometry/sdf.mojo:124; geometry/clip.mojo:25, 42-43 | zero vector | `normalize` returns 0 silently. sdf reports `hit` with a zero normal. rng "unit vector" can be 0, and is non-uniform (normalised cube sample). | document + `normalize_or(fallback)`; fix rng sampling |
| E17 | spatial/hash_grid.mojo:31-32, 52-57, 15-17 | `cell_size ≤ 0`; a box spanning many cells; coordinates beyond ±2²⁰ cells | division by zero → `Int(floor(inf))`; cell odometer unbounded (a 1000-unit floor with cell 1 in 3-D ≈ 1e9 iterations); key wrap (extra candidates only) | invalid input → `raise`; cap span |
| E18 | physics/chain.mojo:571-607, 214-217 | singular H (massless link); `add_link_to(p < -1)` | division by zero → inf/NaN `qdd`; negative parent index accepted | numerical → report; invalid input → `raise` |
| E19 | physics/fem.mojo:273-287 | CG not converged / breakdown | `dv` applied to the state before the caller sees `CgResult` | numerical → check `converged` first |
| E20 | physics/serialize.mojo:53-56, 243-306 | truncated or corrupt snapshot | out-of-bounds token read (not `raise`); joint/cache/hull indices unvalidated → later OOB | environment → `raise` |
| E21 | ecs/sparse_backend.mojo:100-110; ecs/archetype.mojo:268-299 | stale `Entity` after id recycle; `get` of an absent component | aliases the new entity; archetype backend reads the column of an archetype lacking `C` | invariant → assert (F14) |
| E22 | scheduler/gameloop.mojo:33-37 | frame spike beyond `max_steps`; `dt = 0` | `alpha > 1`, debt accumulates without bound; `alpha = inf` | capacity → drop + count (F16) |
| E23 | procedural/anim.mojo:81, 111-112, 214, 290 | `fps = 0`; `frames = 0`; unknown blend mode; clip index out of range | duration inf; output pose left stale; silently geodesic; OOB | invalid input → `raise` at `AnimClip`/`play` |
| E24 | collision/queries.mojo:37-49 | negative or sparse proxy ids | negative index write / large zero-box padding | invalid input → assert dense ids |

---

## 5. Recommended order

**Before any Wave A code**
1. F9: the gate.
2. F6: contract amendments (`core` layer, and FSM/BVH placement per §3(b)/(c)).
3. F15: the runtime-home decision.
4. F8: geometry primitives.
5. F1 + F2 + F3 + F4: `ColliderSet` + `contact_gen` over the `BroadPhase` seam. F3 and F4 become invariants of `ColliderSet`, not solver patches.
6. F5: `BodySet`/`BodyId`/motion type. 17.24 kinematic lands here.
7. F10: boundary validation for the APIs Wave A touches.

**Wave A** proceeds on that base: 17.1, 17.13, 17.7, 17.9, 17.10, 17.23-17.25, 17.32-17.38.

**Wave B entry**
- F11: solver6 split, before 17.17, 17.18 and 17.20.
- F12: chain dense solve and chain contact, before 17.2.
- F17: device-context owner, before 17.17.
- F7: FSM move, before 17.6.
