"""ROADMAP 17.54: parallel narrowphase and contact prep.

Two scenes, 30 timed steps after 30 settling steps, BVH broadphase:
  * box piles: N boxes in columns of 1-4 on a floor (cheap box-box pairs);
  * terrain: N hulls / spheres / boxes on a 33 x 33 heightfield (each body
    against a few dozen triangles: costly, uneven pairs).
Columns: serial step time, then `parallel_collision` with `workers` 1, 2, 4
(this container has 4 cores; the host's other work shares them). Every
parallel run is bit-identical to the serial one (`test_collide_par`).
Built with `-D LUDENS_TRACE`, it also prints the share of the step spent
in each `collect_pairs` stage (serial run). Second table: N = 1e5 box
piles (4 timed steps; the candidate query runs in parallel above
`BP_PAR_MIN` bodies) and N = 4096 terrain bodies all falling at 30 m/s with
CCD on (the fast movers' clamp fractions in parallel).
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from diag.level import TRACE_ON
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _cube(h: Real) -> List[Real]:
    var v = List[Real]()
    for c in range(8):
        v.append(h if c & 1 else -h)
        v.append(h if c & 2 else -h)
        v.append(h if c & 4 else -h)
    return v^


def _build(mut sc: ContactScene6[QuatBody6], scene: Int, n: Int) raises:
    if scene == 0:
        _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 80, 0.5, 80)), Vec3(80, 0.5, 80, 0), True)
        var side = 1
        while side * side * 5 < n * 2:
            side += 1
        var k = 0
        var col = 0
        while k < n:
            var h = 1 + (col * 7) % 4
            var x = Real(col % side) * 0.55 - Real(side) * 0.275
            var z = Real(col // side) * 0.55 - Real(side) * 0.275
            for l in range(h):
                if k >= n:
                    break
                _ = sc.add(QuatBody6.at_rest(Vec3(x, 0.25 + 0.52 * Real(l), z, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
                k += 1
            col += 1
    else:
        var hs = List[Real]()
        for z in range(33):
            for x in range(33):
                hs.append(Real((x * 3 + z * 5) % 7) * 0.08)
        _ = sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs, 33, 33, 1.0, -16, -16)
        var side = 1
        while side * side < n:
            side += 1
        var step = Real(30) / Real(side)
        for k in range(n):
            var p = Vec3(Real(k % side) * step - 15, 1.0, Real(k // side) * step - 15, 0)
            if k % 3 == 0:
                _ = sc.add_hull(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), _cube(0.2), False)
            elif k % 3 == 1:
                _ = sc.add_sphere(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.2)), 0.2, False)
            else:
                _ = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    for i in range(len(sc.bset.bodies)):
        if sc.bset.is_dynamic(i):
            sc.set_can_sleep(sc.bset.id_of(i), False)


def _time(scene: Int, n: Int, par: Bool, workers: Int, split: Bool, steps: Int = 30, ccd: Bool = False) raises -> Tuple[Int, Int]:
    var sc = ContactScene6[QuatBody6]()
    _build(sc, scene, n)
    var cfg = SolverConfig()
    cfg.broadphase = True
    cfg.parallel_collision = par
    cfg.workers = workers
    cfg.ccd = ccd
    for _ in range(steps):
        sc.step(DT, G, cfg)
    if ccd:
        for i in range(len(sc.bset.bodies)):
            if sc.bset.is_dynamic(i):
                sc.set_velocity(sc.bset.id_of(i), Vec3(0, -30, 0, 0), Vec3(0, 0, 0, 0))
    sc.trace.clear()
    var t0 = Int(perf_counter_ns())
    for _ in range(steps):
        sc.step(DT, G, cfg)
    var us = (Int(perf_counter_ns()) - t0) // (steps * 1000)
    comptime if TRACE_ON:
        if split:
            var st = sc.trace.stats()
            var line = String("    split (us/step):")
            for k in range(len(st)):
                line += " " + st[k].name + " " + String(st[k].total_ns // (steps * 1000))
            print(line)
    return (us, len(sc.cache))


def main() raises:
    print("#### Workers sweep (us per step)\n")
    print("| scene | N | contacts | serial us | par w1 | par w2 | par w4 |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    var names: List[String] = ["box piles", "hulls/spheres/boxes on a heightfield"]
    for scene in range(2):
        for n in [64, 1024, 4096]:
            var s0 = _time(scene, n, False, 0, True)
            var p1 = _time(scene, n, True, 1, False)
            var p2 = _time(scene, n, True, 2, False)
            var p4 = _time(scene, n, True, 4, False)
            print("|", names[scene], "|", n, "|", s0[1], "|", s0[0], "|", p1[0], "|", p2[0], "|", p4[0], "|")
    print("")
    print("#### Large N and CCD (us per step)\n")
    print("| case | N | contacts | serial us | par w4 |")
    print("|---|---:|---:|---:|---:|")
    var big = _time(0, 100000, False, 0, True, 4)
    var bigp = _time(0, 100000, True, 4, False, 4)
    print("| box piles (broadphase query in parallel above 1024 bodies) | 100000 |", big[1], "|", big[0], "|", bigp[0], "|")
    var cs = _time(1, 4096, False, 0, True, 10, True)
    var cp = _time(1, 4096, True, 4, False, 10, True)
    print("| heightfield, every body falling at 30 m/s, CCD on (clamp fractions in parallel) | 4096 |", cs[1], "|", cs[0], "|", cp[0], "|")
    print("")
