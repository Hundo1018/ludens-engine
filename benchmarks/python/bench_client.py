"""Python side of benchmarks/bench_python.mojo (ROADMAP 17.21).

Same scene and pushing system as benchmarks/capi/bench_host.c, driven
through the `ludens` package. Prints `row|variant|n|op|total_ns|iters|hash`.
Usage: python bench_client.py N TICKS WARM
"""

import ctypes
import sys
import time

import ludens

n, ticks, warm = (int(a) for a in sys.argv[1:4])


def scene():
    w = ludens.World()
    side = 1
    while side * side * 2 < n:
        side += 1
    L = side * 2.0
    w.add_box((L / 2, -0.5, L / 2), (L / 2 + 1, 0.5, L / 2 + 1), mass=0, static=True)
    bodies = []
    for gx in range(side):
        for gz in range(side):
            for k in range(2):
                if len(bodies) < n:
                    bodies.append(w.add_box((gx * 2 + 1.0, 0.25 + 0.51 * k, gz * 2 + 1.0), (0.25, 0.25, 0.25), mass=1))
    return w, bodies


def row(variant, op, ns, iters, h=0):
    print("row|%s|%d|%s|%d|%d|%d" % (variant, n, op, ns, iters, h))


w, bodies = scene()
pushed = bodies[::10]


def push(world, dt, tick):
    vx = 1.0 if (tick // 60) % 2 == 0 else -1.0
    for b in pushed:
        s = b.state()
        b.set_velocity((vx, s.vel[1], 0.0), s.omega)


w.add_system(push)
w.step_ticks(warm)
t0 = time.perf_counter_ns()
w.step_ticks(ticks)
row("Python: step with a Python PRE system pushing every 10th box", "tick", time.perf_counter_ns() - t0, ticks, w.hash())

reps = max(1, 200000 // n)
t0 = time.perf_counter_ns()
for _ in range(reps):
    for b in bodies:
        b.state()
row("Python: Body.state() per body", "call", time.perf_counter_ns() - t0, reps * n)

buf = (ctypes.c_float * (7 * (n + 1)))()
t0 = time.perf_counter_ns()
for _ in range(reps):
    w.poses_into(buf)
row("Python: World.poses_into (all poses, one call)", "body", time.perf_counter_ns() - t0, reps * (n + 1))

t0 = time.perf_counter_ns()
for _ in range(max(1, reps // 10)):
    w.bodies()
row("Python: World.bodies() (Body + tuple per body)", "body", time.perf_counter_ns() - t0, max(1, reps // 10) * (n + 1))

e = ludens.World()
e.step_ticks(10)
t0 = time.perf_counter_ns()
e.step_ticks(10000)
base = time.perf_counter_ns() - t0
e.add_system(lambda world, dt, tick: None)
t0 = time.perf_counter_ns()
e.step_ticks(10000)
row("Python: one no-op system callback (step cost minus empty-world step)", "callback", max(0, time.perf_counter_ns() - t0 - base), 10000)
