"""Large worlds (ROADMAP 17.8): precision far from the origin per coordinate
strategy, and the cost of rebasing and streaming.

Precision: a box moving 0.5 m/s along x for 1 s starting D metres out; the
row label gives |travel - 0.5 m| for absolute f32 (the engine before 17.8),
f32 with `RebasedF32` (host f64 world coordinates, scene near the origin) and
the f64 build (`build64/`, built by `scripts/build_f64.sh` if missing; run as
a subprocess of `benchmarks/large_world/probe.mojo`). The timed op is the
absolute-f32 run. A small-world row compares the f32 and f64 builds on a
settling stack (the strategies' parity).

Costs: `ContactScene6.shift_origin` per body; `WorldPartition.update` per
call for an observer walking a strip of cells (loads and unloads included).

Run: pixi run mojo run -I build benchmarks/bench_large_world.mojo
"""

from std.python import Python, PythonObject
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.large_world import WorldPos, RebasedF32, Rebaser, WorldPartition, BodySpec, SPEC_BOX

comptime DT: Real = 1.0 / 60.0


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def slow_error(start: Vec3) raises -> Tuple[Float64, Int]:
    var c = SolverConfig()
    c.broadphase = True
    var sc = ContactScene6[QuatBody6]()
    var id = sc.add(QuatBody6.at_rest(start, Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)
    sc.set_can_sleep(id, False)
    sc.set_velocity(id, _v(0.5, 0, 0), _v(0, 0, 0))
    var t0 = now()
    for _ in range(60):
        sc.step(DT, Vec3(0, 0, 0, 0), c)
    var ns = now() - t0
    return (abs(Float64(sc.bset.bodies[0].position()[0]) - Float64(start[0]) - 0.5), ns)


def probe64(sp: PythonObject, mode: String, d: String) raises -> String:
    var r = sp.run(Python.list("mojo", "run", "-I", "build64", "benchmarks/large_world/probe.mojo", mode, d), capture_output=True, text=True)
    if Int(py=r.returncode) != 0:
        raise Error("f64 probe failed: " + String(r.stderr))
    var lines = String(r.stdout).strip().split("\n")
    return String(lines[len(lines) - 1])


def main() raises:
    var t = BenchTable("Large worlds (17.8): precision per coordinate strategy, rebasing and streaming cost")
    var sp = Python.import_module("subprocess")
    var os = Python.import_module("os")
    if not Bool(py=os.path.exists("build64/physics.mojoc")):
        var r = sp.run(Python.list("bash", "scripts/build_f64.sh"), capture_output=True, text=True)
        if Int(py=r.returncode) != 0:
            raise Error("build_f64.sh failed: " + String(r.stderr))

    for d in [1.0, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7]:
        var D = Float64(d)
        var a = slow_error(_v(Real(D), 0, 0))
        var rb = Rebaser(RebasedF32(1024, 64))
        var tmp = ContactScene6[QuatBody6]()
        _ = rb.update(tmp, rb.local(WorldPos(D, 0, 0)), 0)
        var b = slow_error(rb.local(WorldPos(D, 0, 0)))
        var f64 = probe64(sp, "slow", String(Int(D)))
        var label = String("0.5 m/s mover at ") + String(D) + " m: |travel error| f32 " + String(a[0]) + " m, f32 rebased " + String(b[0]) + " m, f64 " + String(f64.split(" ")[1]) + " m"
        t.add(label, 1, "tick (absolute f32)", a[1], 60)

    # small-world parity: f32 vs f64 build, settling stack at the origin
    var c = SolverConfig()
    c.broadphase = True
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(_v(0, -0.5, 0), Inertia3.box(1, 5, 0.5, 5)), _v(5, 0.5, 5), True)
    for k in range(3):
        _ = sc.add(QuatBody6.at_rest(_v(0, 0.25 + 0.51 * Real(k), 0), Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)
    var t0 = now()
    for _ in range(240):
        sc.step(DT, Vec3(0, -9.8, 0, 0), c)
    var ns = now() - t0
    var p = sc.bset.bodies[3].position()
    var f = probe64(sp, "stack", "0").split(" ")
    var dp = max(abs(Float64(p[0]) - Float64(String(f[1]))), abs(Float64(p[1]) - Float64(String(f[2]))), abs(Float64(p[2]) - Float64(String(f[3]))))
    t.add("small world: settling stack, top box |f32 - f64| after 4 s = " + String(dp) + " m", 4, "tick (f32)", ns, 240)

    # rebasing cost
    for n in [1000, 10000]:
        var big = ContactScene6[QuatBody6]()
        for i in range(n):
            _ = big.add(QuatBody6.at_rest(_v(Real(i % 100) * 2, 0.25, Real(i // 100) * 2), Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)
        t0 = now()
        for k in range(20):
            big.shift_origin(_v(64, 0, Real(-64 if k % 2 == 0 else 64)))
        t.add("ContactScene6.shift_origin", n, "body", now() - t0, 20 * n)

    # streaming cost: 64 cells x 16 bodies, observer walks 2 cells per 10 updates
    var wp = WorldPartition(32, 48, 80)
    for cx in range(64):
        for k in range(16):
            _ = wp.add(BodySpec(SPEC_BOX, _v(0.25, 0.25, 0.25), 1, False, WorldPos(Float64(cx) * 32 + 2 + Float64(k % 4) * 6, 0.25, 4 + Float64(k // 4) * 6), Quat.identity(), _v(0, 0, 0), _v(0, 0, 0)))
    var scene = ContactScene6[QuatBody6]()
    var obs = List[WorldPos]()
    obs.append(WorldPos(0, 1, 16))
    var updates = 0
    t0 = now()
    for step in range(300):
        obs[0] = WorldPos(Float64(step) * 6.4, 1, 16)
        wp.update(scene, WorldPos(0, 0, 0), obs, step)
        updates += 1
    var ups = now() - t0
    t.add("WorldPartition.update (1024 bodies in 64 cells, walking observer, " + String(len(wp.events)) + " load/unload events)", 1024, "update", ups, updates)
    t.print_report()
