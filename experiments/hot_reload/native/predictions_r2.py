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
