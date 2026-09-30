"""R1 predictions: hot-reload matrix over memory, comptime, trait, struct,
ABI and boundary edits. Written 2026-09-30, committed BEFORE the engine
features, the variants and the harness that test them exist (see
docs/ROADMAP_EXPERIMENT.md, R1 and R4). Do not edit after the first run;
refuted predictions are recorded next to them, not rewritten.

State added to EngineState for R1, all fields placed BEFORE `core` so that
the phase 1 / H2 / H3 cells keep their meaning (v6 still appends to the
whole state):

  trail:  List[TRAIL_T], TRAIL_T = Int     one append per frame (heap, grows
                                            and reallocates across the swap)
  bodies: List[Body], Body{x: Int, v: Int} 4 bodies, x += mover.advance(v)
  aux:    Aux{grid: InlineArray[Int, GRID_N], mover: ActiveMover}
          GRID_N = 4                        grid[frame % GRID_N] += 1
          ActiveMover = Linear{gain, bias}  generic step over trait Mover;
          trait Mover has a default method `extra()` returning 0

Snapshots store aux with write_value, bodies and trail with write_values;
a stored field whose type or size changed makes the load fail with
LOAD_RETYPE (rejected), as H3 does for Core.

Variants (edit of v1):
  m1_elem       TRAIL_T Int -> Int32             element type of a heap List
  m2_nested     Body gets `mass: Int` in front   layout of a struct INSIDE a heap List
  c1_comptime_n GRID_N 4 -> 8                    comptime value that sizes the state
  t1_impl       Linear.advance doubles the gain  code of a trait implementation
  t2_swap_type  ActiveMover Linear -> Damped{gain, bias, damping}
                                                 comptime alias picks another conformer
  t3_default    Mover.extra() default 0 -> 1     trait default method body
  s1_retype     Core.box_x Float32 -> Float64    field keeps its name, changes type
  a1_abi        engine_update(addr, dt: Float32) -> (addr, dt: Float64)
                                                 exported signature changes; host unchanged

Hypotheses the predictions follow from:
  H-a  the layout id hashes field names, type names, offsets and sizes of
       EngineState as `_walk` sees them; a List is walked into its own
       fields, so the element type appears only through the type name of
       its pointer field. Changing List[Int] to List[Int32] changes that
       name; changing the fields of Body does NOT (the name stays
       `...Body...`). So auto takes the in-place path for m2_nested and
       corrupts it: a guard gap.
  H-b  InlineArray has fewer than 2 reflected fields, so `grid` is one leaf
       whose type name contains N: c1 is a retype -> snapshot rejected.
  H-c  code-only edits (t1, t3), including code reached through generics and
       trait defaults, behave like v2_code.
  H-d  no guard looks at export signatures: a1 corrupts every path that
       runs the new code, including snapshot.
  H-e  Mojo `alloc` uses its own arena (H4 probe), so ASan does not see
       the end of a List buffer: reading past it goes unreported.
"""

R1_VARIANTS = ["m1_elem", "m2_nested", "c1_comptime_n", "t1_impl", "t2_swap_type", "t3_default",
               "s1_retype", "a1_abi"]

# state/label as in run_native.classify; "a|b" = any of these states, label not predicted
_INPLACE_BREAKS = "corrupt|trap"
PREDICTED_R1 = {
    "restart": {v: "lost/new" for v in R1_VARIANTS},
    "samepath": {v: "stale-code/old" for v in R1_VARIANTS},
    "keep": {
        "m1_elem": _INPLACE_BREAKS, "m2_nested": _INPLACE_BREAKS, "c1_comptime_n": _INPLACE_BREAKS,
        "t1_impl": "ok/new", "t2_swap_type": _INPLACE_BREAKS, "t3_default": "ok/new",
        "s1_retype": _INPLACE_BREAKS, "a1_abi": "corrupt/new",
    },
    "snapshot": {
        "m1_elem": "rejected/-", "m2_nested": "ok/new", "c1_comptime_n": "rejected/-",
        "t1_impl": "ok/new", "t2_swap_type": "ok/new", "t3_default": "ok/new",
        "s1_retype": "rejected/-", "a1_abi": "corrupt/new",
    },
    "auto": {
        "m1_elem": "rejected/-", "m2_nested": _INPLACE_BREAKS, "c1_comptime_n": "rejected/-",
        "t1_impl": "ok/new", "t2_swap_type": "ok/new", "t3_default": "ok/new",
        "s1_retype": "rejected/-", "a1_abi": "corrupt/new",
    },
}
PREDICTED_R1["close"] = dict(PREDICTED_R1["keep"])

PREDICTED_USED_R1 = {"auto": {
    "m1_elem": "snapshot", "m2_nested": "inplace", "c1_comptime_n": "snapshot", "t1_impl": "inplace",
    "t2_swap_type": "snapshot", "t3_default": "inplace", "s1_retype": "snapshot", "a1_abi": "inplace",
}}

# Regression: the 48 phase 1 / H2 / H3 cells keep their predictions after the
# R1 state is added (run_native.PREDICTED, unchanged).
REGRESSION_UNCHANGED = True

# ---- boundary scenarios ------------------------------------------------------
# B1 empty state: all 8 entities despawned before the swap (bodies, trail,
# grid unaffected). Same verdicts as with entities.
PREDICTED_B1 = {
    ("close", "v2_code"): "ok/new", ("snapshot", "v2_code"): "ok/new", ("auto", "v2_code"): "ok/new",
    ("close", "v4_layout"): _INPLACE_BREAKS, ("snapshot", "v4_layout"): "ok/new",
    ("auto", "v4_layout"): "ok/new",
}

# B2 repeated swaps: 100 swaps alternating v1 <-> v2_code, one frame after
# each, then the usual 30. Final state equals the oracle; the old module is
# not mapped after the last swap; resident memory grows by less than 2 MiB
# between the first and the last swap (no per-swap leak of state, snapshot
# buffers or mappings).
B2_SWAPS = 100
B2_STRATEGIES = ["close", "snapshot"]
B2_MAX_RSS_GROWTH_KIB = 2048

# B3 ASan (sanitize_native.py, --sanitize address), `detected` = an ASan
# report whose top frame is in the new engine:
#   keep/close/auto x t1_impl   -> not detected (trail reallocates in the new
#                                  code a buffer the old code allocated; one allocator)
#   keep/auto x m2_nested       -> not detected (H-e), although the new code
#                                  reads past the end of the bodies buffer
PREDICTED_B3 = {
    ("keep", "t1_impl"): False, ("close", "t1_impl"): False, ("auto", "t1_impl"): False,
    ("keep", "m2_nested"): False, ("auto", "m2_nested"): False,
}

# Not covered in R1, stated so the gap is on record:
#   swap while another thread is inside engine_update; engine holding a lock
#   (malloc) when it faults; 100k entities through the whole matrix (only
#   snapshot cost is measured, H3); owned raw pointers in the state (the
#   nostatic rule forbids pointer fields).
