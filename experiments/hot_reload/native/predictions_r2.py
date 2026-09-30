"""R2 predictions: hot compile against the ordinary compile. Written
2026-09-30, committed BEFORE compile_speed.py and mono.mojo exist
(docs/ROADMAP_EXPERIMENT.md, R2). Do not edit after the first run.

Conditions, each built with an empty MODULAR_CACHE_DIR (no cache hits),
order shuffled per repetition, N_REPS repetitions:

  so_O3     engine.mojo -> shared lib, default -O3   (the hot path build)
  so_O0     same, -O0
  exe_O3    mono.mojo (engine + a main loop in one program) -> executable,
            -O3                                        (the ordinary build)
  exe_O0    same, -O0
  run_O3    `mojo run mono.mojo`: JIT compile + execute, no external link
  empty_so  a module with one exported function -> shared lib, -O3

Derived:
  hot  = so_O3 + swap (swap from run_native bench, about 0.1 ms)
  cold = exe_O3 + start of the executable + replay of the 70 frames

Hypothesis: at this code size the time is the Mojo front end (the stdlib
import and parameter passes measured in the n=3 pilot), so the kind of
output and the optimisation level change little.
"""

N_REPS = 10

# P1  ordinary vs hot build: median(exe_O3) - median(so_O3) within [-0.3, +0.5] s
P1_EXE_MINUS_SO_S = (-0.3, 0.5)
# P2  cold - hot, end to end, below 0.5 s: in this engine hot reload saves
#     little compile time; what it saves is the running state
P2_COLD_MINUS_HOT_MAX_S = 0.5
# P3  JIT skips the external link: median(run_O3) < median(exe_O3),
#     difference within [0.05, 0.4] s
P3_EXE_MINUS_RUN_S = (0.05, 0.4)
# P4  optimisation level: median(so_O0) / median(so_O3) within [0.8, 1.2].
#     The pilot (n=3) had engine O0 3.29 s vs O3 2.26 s; P4 says that was noise.
P4_O0_OVER_O3 = (0.8, 1.2)
# P5  fixed cost dominates: median(empty_so) / median(so_O3) >= 0.5
P5_EMPTY_OVER_ENGINE_MIN = 0.5

# ---- R2b, 2026-09-30: written after the R2 run, before the follow-ups ran ------
# R2 refuted P1 (exe_O3 - so_O3 = -0.72 s: the program built FASTER than the
# .so) and P4 (so_O0 / so_O3 = 1.41; exe_O0 / exe_O3 = 1.04).
#
# F1 hypothesis: the gap is code the program never reaches. mono.mojo calls 6
#    of the engine's exports; engine_save / engine_load (the schema code, H3:
#    +0.3 s) are dead in the program and removed, while a .so must keep every
#    export. mono_all.mojo calls every export, including save and load.
#    Prediction: median(exe_all_O3) - median(so_O3) within [-0.3, +0.3] s.
F1_EXE_ALL_MINUS_SO_S = (-0.3, 0.3)
# F2 hypothesis: -O0 turns off MLIR-level simplification, so more code reaches
#    the later MLIR passes and LLVM. The n=3 pilot split: MLIR root wall O0
#    2.73 s vs O3 2.18 s. Split of the extra time of so_O0 over so_O3 (median
#    of F2_REPS runs each, --mlir-timing, uncached):
#    MLIR (root wall) difference >= 0.4 s, and the rest (wall - MLIR root:
#    LLVM, link, process) difference within [0.2, 0.8] s.
F2_REPS = 5
F2_MLIR_DIFF_MIN_S = 0.4
F2_REST_DIFF_S = (0.2, 0.8)

# ---- results record, 2026-09-30 (predictions above unchanged) ----------------
# R2 (b5f678b, n=10, seed 1): P2, P3, P5 held; P1 and P4 refuted.
# R2b (faa7cbf): F1 held (+0.225 s): the P1 gap is exports the program never
#   calls. F2-MLIR held (+0.82 s). F2-rest refuted (0.00 s): the MLIR root
#   timer already contains LLVM codegen, so wall - root is only process
#   start; the measurement assumed otherwise. Per-pass: at -O0 the
#   kgen.generator pipeline and RemoveUnusedParams do not run, the lowering
#   passes take 3-4x as long, and the emitted IR has 412 functions vs 111.
REFUTED_R2 = {"P1", "P4", "F2_rest"}
# Replication, seed 2 (n=10): P1 -0.774 s and P4 1.402 refuted again; P2, P5
#   held; P3 FAILED (exe_O3 - run_O3 = -0.024 s; seed 1: +0.080 s). The JIT
#   saving is inside the noise at n=10 (IQRs 0.05-0.14 s): P3 is not supported.
REFUTED_R2 |= {"P3"}

# ---- R2c, 2026-09-30: written before o0_repro.py ran --------------------------
# C-a (the -O0 cost is not specific to this engine): the standalone
#     probes/probe_o0_cost.mojo (List, Dict, String, sort; stdlib only) builds
#     as a shared lib with median(O0) / median(O3) >= 1.2 on Mojo 1.1.0, and its
#     -O0 IR has >= 2x the `define`s of -O3.
# C-b (not fixed on nightly): the same two holds on the nightly installed here
#     (1.2.0.dev2026093005).
# C-c (cache): for an empty module, a warm MODULAR_CACHE_DIR with code never
#     built before is not slower than an empty cache: median(warm) <= median(empty).
C_A_RATIO_MIN = 1.2
C_A_DEFINE_RATIO_MIN = 2.0
# R2c results (9d41e93, n=5 each, interleaved, uncached):
#   1.1.0   probe  O3 2.72 s  O0 2.80 s  ratio 1.03  defines 67 -> 309 (4.6x)
#   1.1.0   engine O3 3.24 s  O0 3.88 s  ratio 1.20  defines 111 -> 412 (3.7x)
#   nightly probe  O3 2.13 s  O0 2.58 s  ratio 1.21  defines 64 -> 316 (4.9x)
#   nightly engine does not build (ecs.schema import fails on the nightly API)
#   cache, 1.1.0, empty module: empty 1.43 s, warm + new code 1.50 s
# C-a time part refuted (1.03); define part held. C-b held (1.21, at the
# bound; defines 4.9x). C-c refuted (warm 0.07 s slower, inside the noise).
# What holds across versions: -O0 sends 4-5x the functions to LLVM. The
# build time penalty depends on the code: 1.0-1.2x standalone, 1.2-1.4x engine.
REFUTED_R2 |= {"C-a_time", "C-c"}
